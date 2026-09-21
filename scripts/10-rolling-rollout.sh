#!/bin/bash
# 10-rolling-rollout.sh — 单镜像逐卡滚动 rollout（每卡独立健康门，失败即中止）
#
# 用法:
#   SGLANG_IMG=sglang:dflash2-ttl-tier4-v5 bash scripts/10-rolling-rollout.sh
#   # 自定义卡序(默认 5800→5801→5802，5803 若已是目标镜像可省略):
#   CARDS="qwen38-27b:3:5800 qwen38-27b-gpu0:0:5801" SGLANG_IMG=... bash scripts/10-rolling-rollout.sh
#
# 每卡流程: 摘 SMG worker → launch-awq.sh 重拉 → si=200 健康门(≤3min)
#           → SMG 重注册(auto-register 优先, 缺失则手动 POST) → 冒烟 chat → 60s 稳定窗
#
# 注意: SMG 重注册检查窗必须 ≥ autoreg_watch 周期(≥30s)，否则 rollout 的裸 POST 会
#       抢在 auto-register 前把 worker 登记成 model=unknown(见 OPERATIONS.md 五.4 竞态)。
set -uo pipefail
cd "$(dirname "$0")/.."

SGLANG_IMG="${SGLANG_IMG:?need SGLANG_IMG (target image tag)}"
KEY="${SGLANG_API_KEY:-sk-qwen38-GE0CIlgTQsVLj41laThTVb-6wY2khVtT}"
CPKEY=$(cat gateway/router-cp.key 2>/dev/null || cat /mnt/data/sglang-qwen38/router-cp.key)
GW_PORT="${GW_PORT:-30010}"
CARDS="${CARDS:-qwen38-27b:3:5800 qwen38-27b-gpu0:0:5801 qwen38-27b-gpu1:1:5802}"
LOG="${LOG:-/tmp/v5-rollout-$(date +%y%m%d).log}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# worker id 按 port 查
wid_for_port() {
  curl -s -H "Authorization: Bearer $CPKEY" "http://127.0.0.1:$GW_PORT/workers" \
    | python3 -c "import sys,json
for w in json.load(sys.stdin).get('workers',[]):
    if w['url'].endswith(':$1'): print(w['id'])" 2>/dev/null
}

rollout_card() {
  local CONTAINER=$1 GPU=$2 PORT=$3 MODEL=qwen3.8
  log "=== ROLLING $CONTAINER (GPU$GPU :$PORT) ==="

  # 1) 摘 SMG worker
  local WID
  WID=$(wid_for_port "$PORT")
  if [ -n "$WID" ]; then
    curl -s -X DELETE -H "Authorization: Bearer $CPKEY" \
      "http://127.0.0.1:$GW_PORT/workers/$WID" >> "$LOG" 2>&1
    log "deregistered SMG worker $WID for :$PORT"; sleep 5
  fi

  # 2) 重拉目标镜像
  SGLANG_IMG="$SGLANG_IMG" bash sglang/launch-awq.sh "$CONTAINER" "$GPU" "$PORT" "$MODEL" \
    2>&1 | tee -a "$LOG" | tail -20

  # 3) 健康门: si=200 (≤3min)
  local code=000 i
  for i in $(seq 1 36); do
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -H "Authorization: Bearer $KEY" \
      "http://127.0.0.1:$PORT/server_info" 2>/dev/null)
    [ "$code" = "200" ] && break
    sleep 5
  done
  if [ "$code" != "200" ]; then
    log "ERROR: $CONTAINER 未达健康 (si=$code) 3min — 中止 rollout"; return 1
  fi
  log "HEALTHY: $CONTAINER si=200"

  # 4) SMG 重注册: 等 autoreg 先跑(≥30s)，仍缺则手动全元数据 POST
  sleep 35
  WID=$(wid_for_port "$PORT")
  if [ -z "$WID" ]; then
    log "WARN: 未自动注册，手动 POST 全元数据"
    local MID
    MID=$(curl -s -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/v1/models" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
    curl -s -X POST -H "Authorization: Bearer $CPKEY" -H "Content-Type: application/json" \
      -d "{\"url\":\"http://127.0.0.1:$PORT\",\"model_id\":\"$MID\",\"worker_type\":\"regular\",\"api_key\":\"$KEY\"}" \
      "http://127.0.0.1:$GW_PORT/workers" >> "$LOG" 2>&1; sleep 5
  fi
  log "SMG worker 已就位 :$PORT"

  # 5) 冒烟 chat
  local CHAT
  CHAT=$(curl -s -o /dev/null -w "%{http_code}" -m 30 -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen3.8","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
    "http://127.0.0.1:$PORT/v1/chat/completions" 2>/dev/null)
  log "smoke chat :$PORT → $CHAT"
  [ "$CHAT" = "200" ] || log "WARN: 冒烟非 200 ($CHAT)，si 已 200，继续(可能预热)"

  # 6) 稳定窗 + 复查
  log "稳定 60s..."; sleep 60
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -H "Authorization: Bearer $KEY" \
    "http://127.0.0.1:$PORT/server_info")
  log "POST-STAB: si=$code"
  log "=== ROLL COMPLETE: $CONTAINER ==="
  return 0
}

echo "=== ROLLING ROLLOUT START $(date) img=$SGLANG_IMG ===" > "$LOG"
for spec in $CARDS; do
  IFS=: read -r C G P <<< "$spec"
  rollout_card "$C" "$G" "$P" || { log "ABORT at :$P"; exit 1; }
done
log "=== ROLLOUT COMPLETE $(date) ==="
