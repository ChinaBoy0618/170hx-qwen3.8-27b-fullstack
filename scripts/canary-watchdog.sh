#!/bin/bash
# canary-watchdog.sh — 单卡 canary 看门狗（60s 三查 + chat 4-strike + gm>3s 判死）
#
# 用法:
#   PORT=5803 CONTAINER=qwen38-27b-gpu2 DURATION=7200 INTERVAL=60 bash scripts/canary-watchdog.sh
#
# 判死(立即 dump 证据 + 摘 SMG worker + touch STOPPED):
#   容器非 running / si!=200 / chat=500 / chat 连续 4 次 000(超时) / gm 耗时>3s
# 判活判据说明: si=/server_info(快, 引擎死会挂或慢), gm=/get_model_info(>3s=僵尸签名),
#   chat 用 60s 超时(16 并发饱和下 5-token 探活可能排队 >20s，避免假阳性，见 v5b 修正)。
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:?need PORT}"
CONTAINER="${CONTAINER:?need CONTAINER}"
KEY="${SGLANG_API_KEY:-sk-qwen38-GE0CIlgTQsVLj41laThTVb-6wY2khVtT}"
CPKEY=$(cat gateway/router-cp.key 2>/dev/null || cat /mnt/data/sglang-qwen38/router-cp.key)
GW_PORT="${GW_PORT:-30010}"
DURATION="${DURATION:-7200}"
INTERVAL="${INTERVAL:-60}"
MODEL="${MODEL:-qwen3.8}"
STAMP=$(date +%y%m%d-%H%M)
LOG="${LOG:-/tmp/canary-${STAMP}-watchdog.log}"
END=$(( $(date +%s) + DURATION ))
chat_strikes=0

echo "=== canary watchdog $(date) port=$PORT dur=${DURATION}s int=${INTERVAL}s ===" > "$LOG"

while [ "$(date +%s)" -lt "$END" ]; do
  ts=$(date "+%H:%M:%S")
  st=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)
  si_code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/server_info" 2>/dev/null)
  si_time=$(curl -s -o /dev/null -w "%{time_total}" -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/server_info" 2>/dev/null)
  gm_time=$(curl -s -o /dev/null -w "%{time_total}" -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/get_model_info" 2>/dev/null)
  chat_code=$(curl -s -o /dev/null -w "%{http_code}" -m 60 -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1=\"}],\"max_tokens\":5}" \
    "http://127.0.0.1:$PORT/v1/chat/completions" 2>/dev/null)
  mem_avail=$(free -g | awk 'NR==2{print $7}')
  l3_used=$(df -h /mnt/nvme-model 2>/dev/null | awk 'NR==2{print $5}')
  gm_slow=0; awk -v t="$gm_time" 'BEGIN{exit !(t>3.0)}' && gm_slow=1
  echo "$ts state=$st si=$si_code/${si_time}s gm=${gm_time}s gm_slow=$gm_slow chat=$chat_code mem=${mem_avail}G l3=$l3_used" >> "$LOG"

  if [ "$chat_code" = "000" ]; then chat_strikes=$((chat_strikes+1)); else chat_strikes=0; fi
  if [ "$st" != "running" ] || [ "$si_code" != "200" ] || [ "$chat_code" = "500" ] \
     || [ "$chat_strikes" -ge 4 ] || [ "$gm_slow" = "1" ]; then
    echo "$ts DEAD-DETECTED state=$st si=$si_code/${si_time}s gm=${gm_time}s gm_slow=$gm_slow chat=$chat_code strikes=$chat_strikes" >> "$LOG"
    docker logs --tail 400 "$CONTAINER" > "/tmp/canary-${STAMP}-crash.log" 2>&1
    nvidia-smi > "/tmp/canary-${STAMP}-nvidia.log" 2>&1
    free -h > "/tmp/canary-${STAMP}-mem.log" 2>&1
    WID=$(curl -s -H "Authorization: Bearer $CPKEY" "http://127.0.0.1:$GW_PORT/workers" \
      | python3 -c "import sys,json
for w in json.load(sys.stdin).get('workers',[]):
    if w['url'].endswith(':$PORT'): print(w['id'])" 2>/dev/null)
    [ -n "$WID" ] && { curl -s -X DELETE -H "Authorization: Bearer $CPKEY" "http://127.0.0.1:$GW_PORT/workers/$WID" >> "$LOG" 2>&1
      echo; echo "$ts SMG worker $WID deregistered" >> "$LOG"; }
    touch "/tmp/canary-${STAMP}-STOPPED"
    echo "$ts STOPPED: dead, evidence dumped, card deregistered" >> "$LOG"
    exit 1
  fi
  sleep "$INTERVAL"
done

echo "$(date "+%H:%M:%S") SOAK-COMPLETE: survived without death" >> "$LOG"
touch "/tmp/canary-${STAMP}-DONE"
