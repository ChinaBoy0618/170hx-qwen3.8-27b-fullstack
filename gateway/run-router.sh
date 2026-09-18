#!/bin/bash
# SGLang sessionkey-v2 网关 — 容器版(2026-08-28 容器化, 2026-09-17 切会话感知路由)
# 09-17 切换: 镜像 sglang-gateway:sessionkey-v2 = 0821 原树(含全部 4 旧补丁: 08-21 main 快照 /
#   #33138 tie-break / B+剥null / anthropic raw-passthrough) + sessionkey 改动(会话粘滞+路由表持久化)重编,
#   canary :30011 已全项验证通过(旧补丁在位/CC会话头透传/粘滞/持久化/零回归)。
#   路由: --policy manual --assignment-mode min_load --routing-map-file /mnt/gw-data/session-routing.json
#   key 阶梯: x-smg-routing-key > x-claude-code-session-id > c:xxh3(前8192字符) > min_load
#   落盘: 宿主 /mnt/data/sglang-qwen38/gw-data/session-routing.json(60s 原子快照, 4h TTL)
#   回滚: 恢复本文件 .bak-cacheaware-0917 (main-bnull-ant + cache_aware 0.2/4/1.1) + bash run-router.sh restart(秒级)
# 历史: 09-17 早曾回滚 09-16 sessionkey 试用(raw-passthrough 补丁丢失致404, 见 .bak-sessionkey-rollback-0917)
# 09-17 回滚: 09-16 sessionkey(manual policy 会话感知路由)试用已撤销,恢复本 cache_aware 配置。
#   原因: main-bnull-ant 的 anthropic raw-passthrough 补丁在 sessionkey 重编时丢失,
#   导致 /v1/messages (CC 协议) 404。重做时须先把该补丁合回源码树再编。
#   sessionkey 版备份: run-router.sh.bak-sessionkey-rollback-0917 / 镜像 sglang-gateway:sessionkey 保留未删。
# 镜像 sglang-gateway:main-bnull-ant (08-21 main 快照 + #33138 tie-break + B+剥null + anthropic raw-passthrough)
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
IMG=sglang-gateway:sessionkey-v2
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-30010}
PROM_PORT=${PROM_PORT:-29010}
IGW=${IGW:-1}
KEY="${SGLANG_API_KEY:?need to export SGLANG_API_KEY (see .env.example)}"
CP_KEY_FILE=/mnt/data/sglang-qwen38/router-cp.key
MODEL=/mnt/data/models/Qwen3.8-27B-Channel-INT8-w8a8
GW_DATA=/mnt/data/sglang-qwen38/gw-data
mkdir -p "$GW_DATA"
CP_KEY_OPT=""
[ -f "$CP_KEY_FILE" ] && CP_KEY_OPT="--control-plane-api-keys 1:admin:admin:$(cat $CP_KEY_FILE)"
IGW_OPT=""
[ "$IGW" = 1 ] && IGW_OPT="--enable-igw"

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
    docker run -d --name "$NAME" \
      --network host --restart unless-stopped \
      -v "$MODEL":/model:ro \
      -v "$GW_DATA":/mnt/gw-data \
      "$IMG" \
      $IGW_OPT \
      --worker-urls $WORKER_URLS \
      --policy manual --assignment-mode min_load --routing-map-file /mnt/gw-data/session-routing.json \
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
    fi
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
esac
