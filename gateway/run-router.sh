#!/bin/bash
# SGLang 会话感知网关 — 容器版(2026-08-28 起生效)
# 09-16 切换: 镜像 sglang-gateway:sessionkey + --policy manual --assignment-mode min_load
#   + --routing-map-file /mnt/gw-data/session-routing.json(路由表持久化,重启恢复)。
#   key 阶梯: x-smg-routing-key > x-claude-code-session-id > c:xxh3(前8192字符) > min_load。
#   回滚: 改回 --policy cache_aware --cache-threshold 0.2 --balance-abs-threshold 4
#         --balance-rel-threshold 1.1 + IMG=sglang-gateway:main-bnull-ant + restart(仅网关,秒级)
# 原 main-bnull-ant (08-21 main 快照 + #33138 tie-break + B+剥null + anthropic raw-passthrough)
# 替代旧 nohup python 启动;--restart unless-stopped 宿主重启自愈
# 前置:worker 实例由 launch-int8.sh / launch-flashnext-opt.sh 管理(5800-5899 固定端口)
# 用法: bash run-router.sh [start|stop|restart|status|discover|register]
#
# 09-03 IGW 模式(修跨模型 misroute): IGW=1 时加 --enable-igw + start 后逐个 POST /workers
#   带 model_id(model 从 worker /v1/models 实查)。原因: 无 IGW 时 Rust 核不看 model 字段,
#   cache_aware 前缀亲和会把 qwen3.8-flash-next 路由到 27B;且该 build IGW 模式不吃静态
#   --worker-urls(启动日志 workers:[]),必须控制面动态注册。
#   金丝雀: NAME=sglang-gw-canary HOST=127.0.0.1 PORT=30011 PROM_PORT=29011 bash run-router.sh start
#   回滚:   IGW=0 bash run-router.sh restart  (即旧行为)
# 历史版本: run-router.sh.bak-0828-nohup / .bak-0903-pre-igw
set -uo pipefail

NAME=${NAME:-sglang-gateway}
# 09-19: 默认切到带 auto-register 的镜像(已 patch launch_router.py, 启动时读 SMG_* env 自动 POST /workers)。
#   回滚: IMG=sglang-gateway:sessionkey-pre-autoreg-0919
IMG=${IMG:-sglang-gateway:sessionkey-auto-register-0919}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-30010}
PROM_PORT=${PROM_PORT:-29010}
IGW=${IGW:-1}
KEY="sk-qwen38-GE0CIlgTQsVLj41laThTVb-6wY2khVtT"
CP_KEY_FILE=/mnt/data/sglang-qwen38/router-cp.key
MODEL=/mnt/data/models/Qwen3.8-27B-Channel-INT8-w8a8
CP_KEY_OPT=""
[ -f "$CP_KEY_FILE" ] && CP_KEY_OPT="--control-plane-api-keys 1:admin:admin:$(cat $CP_KEY_FILE)"
IGW_OPT=""
[ "$IGW" = 1 ] && IGW_OPT="--enable-igw"
# 09-19: 给容器传 SMG_* env, 让 _autoreg.py 后台线程自动 register。
#   SMG_WORKER_URLS 用 ; 作分隔符(避免 docker -e 解析冲突), 容器内 split(';').
#   必须在 start 函数里构造(因为 WORKER_URLS 要先 build_worker_urls 拿到)。
AUTOREG_ENV=()

# 自动发现: 返回排序去重后的 host 端口列表 (5800-5899 范围内, 一行一个)
discover_workers() {
  docker ps --filter "name=qwen38-" --filter "status=running" --format "{{.Ports}}" \
    | grep -oE '0\.0\.0\.0:5[0-9]{3}->[0-9]+' \
    | sed -E 's/.*:(5[0-9]{3})->[0-9]+/\1/' \
    | awk '$1 >= 5800 && $1 <= 5899' \
    | sort -n | uniq
}

build_worker_urls() {
  local urls=()
  for p in $(discover_workers); do
    urls+=("http://127.0.0.1:$p")
  done
  echo "${urls[@]}"
}

# 查 worker 实际 served model (27B->qwen3.8 / flashnext->qwen3.8-flash-next)
worker_model_id() {
  curl -s -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$1/v1/models" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null
}

# 09-20 启动顺序: 在 docker run SMG 前, 等 worker discover 非空 + 全 health 200。
#   原顺序 SMG 先于 worker 启动 → 容器内 _autoreg.py 180s 端口超时放弃, 后到的 worker 永远不注册(09-20 实证)。
#   等到 worker 就绪再起 SMG, autoreg 一次性扫描即可命中全部 worker。
wait_for_workers() {
  local target="${1:-1}" timeout="${2:-300}" elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local got=0 up=0
    for p in $(discover_workers); do
      got=$((got+1))
      # SGLang /health 空 body 但 HTTP 200 即 OK(curl -sf); -m 2 防单点卡
      if curl -sf -m 2 "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
        up=$((up+1))
      fi
    done
    if [ "$got" -ge "$target" ] && [ "$up" -eq "$got" ]; then
      echo "[$(date +%H:%M:%S)] wait_for_workers: $up/$got ports up, ready"
      return 0
    fi
    sleep 5; elapsed=$((elapsed+5))
  done
  echo "[$(date +%H:%M:%S)] wait_for_workers: TIMEOUT after ${timeout}s, continue anyway (got=$got up=$up)"
  return 1
}

# 09-20 autoreg 长在线 watcher: 宿主后台跑, 每 30s 比对 discover_workers ↔ IGW /workers,
#   差集补注册, 不健康 worker 删除重注。修 _autoreg.py 180s 一次性 + 启动快照的 bug。
autoreg_watch() {
  # set +u: 函数内引用 SMG_WATCH_LOG / SMG_WATCH_INTERVAL 等可能未在调用方设的 env
  set +u
  local CP_VAL=$([ -f "$CP_KEY_FILE" ] && cat "$CP_KEY_FILE")
  if [ -z "$CP_VAL" ]; then echo "autoreg-watch: CP key missing, abort" >&2; return 1; fi
  echo "[$(date +%H:%M:%S)] autoreg-watch: START (interval=${SMG_WATCH_INTERVAL:-30}s, log=${SMG_WATCH_LOG:-/tmp/smg-autoreg-watch.log})"
  local LOG="${SMG_WATCH_LOG:-/tmp/smg-autoreg-watch.log}"
  while true; do
    # 1) 等 SMG 就绪(起 watcher 时 SMG 可能还没起)
    if ! curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      sleep 5; continue
    fi
    # 2) 当前 IGW 已注册 worker 集合(按 port)
    local reg_ports=""
    reg_ports=$(curl -s -m 3 -H "Authorization: Bearer $CP_VAL" "http://127.0.0.1:$PORT/workers" \
      | python3 -c "import json,sys; print(' '.join(w['url'].rsplit(':',1)[-1] for w in json.load(sys.stdin).get('workers',[])))" 2>/dev/null)
    # 3) discover 出来的实际可用 worker
    local live_ports=""
    for p in $(discover_workers); do
      if curl -sf -m 2 "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
        live_ports="$live_ports $p"
      fi
    done
    # 4) 差集: live 但未注册 → POST
    for p in $live_ports; do
      if ! echo " $reg_ports " | grep -q " $p "; then
        local mid=$(worker_model_id "$p")
        if [ -z "$mid" ]; then continue; fi
        local body="{\"url\":\"http://127.0.0.1:$p\",\"model_id\":\"$mid\",\"worker_type\":\"regular\",\"api_key\":\"$KEY\"}"
        local code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/workers" \
          -H "Authorization: Bearer $CP_VAL" -H "Content-Type: application/json" -d "$body")
        echo "[$(date +%H:%M:%S)] autoreg-watch: add :$p model=$mid -> HTTP $code" >> "$LOG"
      fi
    done
    # 5) 不在 live 但在 reg → DELETE 重注(端口已 up 但模型就绪延迟 / health 短暂失败)
    for p in $reg_ports; do
      if ! echo " $live_ports " | grep -q " $p "; then
        # 不主动 DELETE: 万一 worker 临时 OOM 复活就行;只 DELETE 完全不可达的(用 ss -ltn 判端口 listen)
        if ! ss -ltn 2>/dev/null | grep -q ":$p "; then
          local wid=$(curl -s -m 3 -H "Authorization: Bearer $CP_VAL" "http://127.0.0.1:$PORT/workers" \
            | python3 -c "import json,sys; ws=[w for w in json.load(sys.stdin).get('workers',[]) if w['url'].endswith(':$p')]; print(ws[0]['id'] if ws else '')" 2>/dev/null)
          if [ -n "$wid" ]; then
            curl -s -o /dev/null -X DELETE "http://127.0.0.1:$PORT/workers/$wid" -H "Authorization: Bearer $CP_VAL"
            echo "[$(date +%H:%M:%S)] autoreg-watch: del :$p (port dead, wid=$wid)" >> "$LOG"
          fi
        fi
      fi
    done
    sleep "${SMG_WATCH_INTERVAL:-30}"
  done
}

# IGW 模式: 控制面逐个注册, body 带 model_id (worker_type=regular, api_key=worker 鉴权键)
register_workers() {
  local CP_VAL=$([ -f "$CP_KEY_FILE" ] && cat "$CP_KEY_FILE")
  if [ -z "$CP_VAL" ]; then echo "register: CP key missing ($CP_KEY_FILE), cannot register" >&2; return 1; fi
  # 09-10 竞态修复: router ready 可能晚于 do_start 的 60s 健康窗口(实测 ~86s),
  #   端口未 listen 时 POST /workers 全 000, 且旧 /tmp/smg-reg-*.out 残留造成"假 accepted"。
  #   先等数据面 /health 可达(至多 120s)再注册。
  local w wok=0
  for w in $(seq 1 120); do
    curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { wok=1; break; }
    sleep 1
  done
  [ "$wok" = 1 ] || echo "register: 数据面 :$PORT 120s 未就绪, 仍尝试注册..." >&2
  local p mid code attempt
  for p in $(discover_workers); do
    mid=$(worker_model_id "$p")
    if [ -z "$mid" ]; then
      echo "[$(date +%H:%M:%S)] worker :$p /v1/models 无响应(model 未就绪?), 跳过 — 就绪后补注册: NAME=$NAME PORT=$PORT bash $0 register"
      continue
    fi
    for attempt in 1 2 3; do
      rm -f "/tmp/smg-reg-$p.out"
      code=$(curl -s -o "/tmp/smg-reg-$p.out" -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/workers" \
        -H "Authorization: Bearer $CP_VAL" -H "Content-Type: application/json" \
        -d "{\"url\":\"http://127.0.0.1:$p\",\"model_id\":\"$mid\",\"worker_type\":\"regular\",\"api_key\":\"$KEY\"}")
      case "$code" in 200|202) break;; esac
      sleep 5
    done
    echo "[$(date +%H:%M:%S)] register :$p model=$mid -> HTTP $code attempt=$attempt $(head -c 200 /tmp/smg-reg-$p.out 2>/dev/null)"
  done
}

case "${1:-start}" in
  start)
    WORKER_URLS=$(build_worker_urls)
    if [ -z "$WORKER_URLS" ]; then
      echo "ERROR: no qwen38-* Up containers found in 5800-5899 range" >&2
      exit 1
    fi
    if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      echo "$NAME already running"; exit 0
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "[$(date +%H:%M:%S)] discovered workers: $WORKER_URLS (IGW=$IGW)"
    # 09-20 启动顺序: docker run SMG 前等 worker 全 health 200(默认至少 1 个,等齐最多 300s)。
    #   SMG_WORKER_URLS 启动期快照 → autoreg 一次性扫过才能命中所有 worker, 否则后到的漏注册。
    wait_for_workers 1 "${SMG_WAIT_TIMEOUT:-300}"
    # 09-19: 构造 SMG_* env(把 WORKER_URLS 传给容器,容器内 _autoreg.py 后台线程自动 register)
    if [ "$IGW" = 1 ] && [ -f "$CP_KEY_FILE" ]; then
      AUTOREG_ENV=(
        -e "SMG_WORKER_URLS=$(echo $WORKER_URLS | tr ' ' ';')"
        -e "SMG_WORKER_API_KEY=$KEY"
        -e "SMG_CONTROL_PLANE_KEY=$(cat $CP_KEY_FILE)"
        -e "SMG_HOST=127.0.0.1"
        -e "SMG_PORT=$PORT"
      )
    fi
    # 秒级故障切换参数(08-28 验收: 摘除≤4.5s/恢复3s/500型零失败)
    # 09-09 hc-tune(基线): /health 底延迟恒~1s(dummy generate)+长文 prefill 期间顶到8-15s,
    #   而路由侧超时5s+连续2败即摘 → 忙卡被踢(09-09 08:34 UTC :5800 14连败掉线实证)。
    #   timeout 5→10s(覆盖13s prefill尾)+ failure-threshold 2→3(需~30s持续超10s才摘,
    #   死端口仍~6s秒级摘除);success-threshold=1 保留,恢复仍秒级。备份 .bak-0909-hc-tune
    # 09-10 A3 治本: 换探活端点 /get_model_info(底延迟 1s→5ms,长 prefill 不再阻塞探活),
    #   timeout 回 3s(端点 5ms 余量充足);failure/success/interval 保留不动(秒级切换核心)。
    #   备份 .bak-a3-0910(本机 10s/3旧)、.before-canary(改 endpoint 前 10s/3版)、.bak-0909-hc-tune
    # 09-10 熔断放宽(链路重构: worker 直吃 cc-haha 大请求, 原 cb 1/20 把长 prefill 误杀):
    #   cb-failure-threshold 1→10, cb-timeout-duration-secs 20→60(两者回 smg 默认),
    #   加 --request-timeout-secs 600(硬上限, smg 默认 1800 过长)。
    #   回滚锚 run-router.sh.bak-0910-cb-relax(1/20, 无 request-timeout)。
    # 09-10 注册竞态修复: register_workers 先等数据面 /health 可达再注册 + 非2xx重试(见函数内注释)。
    # 09-16 会话感知路由: --policy manual --assignment-mode min_load,路由表持久化到 gw-data
    #   (容器内 /mnt/gw-data/session-routing.json),网关重启自动恢复在途会话→原卡,不重 prefill。
    mkdir -p /mnt/data/sglang-qwen38/gw-data
    docker run -d --name "$NAME" \
      --network host --restart unless-stopped \
      -v "$MODEL":/model:ro \
      -v /mnt/data/sglang-qwen38/gw-data:/mnt/gw-data \
      "${AUTOREG_ENV[@]}" \
      "$IMG" \
      $IGW_OPT \
      --worker-urls $WORKER_URLS \
      --policy manual \
      --assignment-mode min_load \
      --routing-map-file /mnt/gw-data/session-routing.json \
      --model-path /model \
      --api-key "$KEY" \
      $CP_KEY_OPT \
      --host "$HOST" --port "$PORT" --prometheus-port "$PROM_PORT" \
      --health-check-timeout-secs 3 --health-check-interval-secs 2 \
      --health-failure-threshold 3 --health-success-threshold 1 \
      --health-check-endpoint /get_model_info \
      --cb-failure-threshold 10 --cb-timeout-duration-secs 60 \
      --retry-max-retries 2 \
      --request-timeout-secs 600
    ok=0
    for i in $(seq 1 60); do
      curl -s -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ok=1; break; }; sleep 1
    done
    if [ "$ok" = 1 ]; then echo "gateway: UP (:$PORT)"; else
      # 坑: 健康检查窗口可能不够 tokenizer 加载(09-03 实测 30s 假阴性,容器实际 Up)
      echo "gateway health check TIMEOUT (可能假阴性, docker ps 复核), 仍尝试注册..."
    fi
    if [ "$IGW" = 1 ]; then
      echo "IGW mode: registering workers with model_id..."
      register_workers
      # 09-20 长在线 watcher: 宿主后台跑, 每 30s 差集补注册 / 死端口删 worker。
      #   修 _autoreg.py 一次性 180s 超时 + 启动快照的漏注册(09-20 实证)。
      #   默认 30s 周期, 可用 SMG_WATCH_INTERVAL / SMG_WATCH_DISABLE=1 调。
      if [ "${SMG_WATCH_DISABLE:-0}" != "1" ]; then
        # 先 kill 旧的同名 watcher(同名进程同名参数保证幂等)
        pkill -f "run-router.sh watch" 2>/dev/null || true
        # /var/log 普通用户写不动, 直接落 /tmp
        SMG_WATCH_LOG="${SMG_WATCH_LOG:-/tmp/smg-autoreg-watch.log}"
        # 关键: 通过 python Popen+start_new_session 起, 立刻 exit 让 watcher PPID=1(init 收养),
        #   这样 start 命令返回后无论父 shell 是否被 SIGHUP, watcher 都活。09-20 实证 setsid+nohup 不够。
        python3 - "$SMG_WATCH_LOG" "${SMG_WATCH_INTERVAL:-30}" "$PORT" "$0" <<'PY'
import os, subprocess, sys
log, interval, port, script = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
env = dict(os.environ)
env["SMG_WATCH_LOG"] = log
env["SMG_WATCH_INTERVAL"] = interval
env["SMG_PORT"] = port
p = subprocess.Popen(
    ["bash", script, "watch"],
    stdin=subprocess.DEVNULL,
    stdout=open(log, "a"), stderr=subprocess.STDOUT,
    env=env, start_new_session=True
)
open("/tmp/smg-autoreg-watch.pid", "w").write(str(p.pid))
print(p.pid)
PY
        echo "[$(date +%H:%M:%S)] autoreg-watch started (pid=$(cat /tmp/smg-autoreg-watch.pid 2>/dev/null), log=$SMG_WATCH_LOG, interval=${SMG_WATCH_INTERVAL:-30}s)"
      fi
    fi
    ;;
  watch)
    autoreg_watch
    ;;
  stop)
    docker rm -f "$NAME" && echo "gateway stopped" || echo "not running"
    ;;
  restart)
    "$0" stop
    # 坑: prometheus 端口释放慢,立即 start 会 panic Address already in use,等它空了再起
    for i in $(seq 1 60); do ss -ltn | grep -q ":$PROM_PORT " || break; sleep 1; done
    "$0" start
    ;;
  status)
    if curl -s -m 3 "http://127.0.0.1:$PORT/health" >/dev/null; then
      echo "gateway: UP  container: $(docker ps --filter name=$NAME --format '{{.Status}}')"
    else
      echo "gateway: DOWN"; exit 1
    fi
    echo "readiness: $(curl -s -m 3 "http://127.0.0.1:$PORT/readiness")"
    CP_VAL=$([ -f "$CP_KEY_FILE" ] && cat "$CP_KEY_FILE" || echo "")
    if [ -n "$CP_VAL" ]; then
      curl -s -m 3 -H "Authorization: Bearer $CP_VAL" "http://127.0.0.1:$PORT/workers" | python3 -c "
import json,sys
for w in json.load(sys.stdin)['workers']:
    print('worker', w['url'].split('//')[1], 'model='+w['model_id'], 'healthy='+str(w['is_healthy']), 'load='+str(w['load']))"
    fi
    curl -s -m 3 "http://127.0.0.1:$PROM_PORT/metrics" | grep -E 'smg_router_requests_total|smg_http_requests_total.*chat' | grep -v '^#' | head -5
    ;;
  discover)
    echo "discovered worker ports:"; discover_workers
    ;;
  register)
    register_workers
    ;;
  watch)
    autoreg_watch
    ;;
esac
