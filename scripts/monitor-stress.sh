#!/bin/bash
# monitor-stress.sh — 压测伴随监控：压测进程存活 + 每卡 si/gm 探活 + 僵尸签名早断 + 自旋线程检查
#
# 用法:
#   STRESS_PIDS="stress-5800.py stress-5802.py" CARDS="5800:qwen38-27b 5802:qwen38-27b-gpu1" \
#     bash scripts/monitor-stress.sh
#
# 判据:
#   - 任一压测进程退出 → 等另一个也退出（BOTH DONE）后收尾
#   - 任一卡 si!=200 → ZOMBIE-SIG 早断（容器活引擎死的鉴别签名之一）
#   - 收尾: 各卡 si/gm 时延 + 压测日志尾部 + 调度器线程 CPU top5(第二自旋线程 = 驱逐活锁回归)
set -uo pipefail

KEY="${SGLANG_API_KEY:-sk-qwen38-GE0CIlgTQsVLj41laThTVb-6wY2khVtT}"
STRESS_PIDS="${STRESS_PIDS:-stress-5800.py stress-5802.py}"
# "port:container" 列表
CARDS="${CARDS:-5800:qwen38-27b 5802:qwen38-27b-gpu1}"
INTERVAL="${INTERVAL:-20}"
MAX_ROUNDS="${MAX_ROUNDS:-200}"

alive_any=0
for s in $STRESS_PIDS; do
  [ "$(pgrep -f "$s" | wc -l)" != "0" ] && alive_any=1
done

for i in $(seq 1 "$MAX_ROUNDS"); do
  alive_any=0
  for s in $STRESS_PIDS; do
    [ "$(pgrep -f "$s" | wc -l)" != "0" ] && alive_any=1
  done
  [ "$alive_any" = "0" ] && { echo "=== BOTH STRESS DONE ==="; break; }
  bad=0
  for pc in $CARDS; do
    p="${pc%%:*}"
    si=$(curl -s -o /dev/null -w "%{http_code}" -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$p/server_info" 2>/dev/null)
    if [ "$si" != "200" ]; then
      echo "=== ZOMBIE-SIG si:$p=$si at $(date +%H:%M:%S) ==="
      bad=1; break
    fi
  done
  [ "$bad" = "1" ] && break
  sleep "$INTERVAL"
done

# 收尾: 压测日志尾部 + si/gm 时延 + 线程自旋检查
for s in $STRESS_PIDS; do
  case "$s" in *.py) log="/tmp/${s%.py}.log";; *) log="/tmp/$s.log";; esac
  echo "=== FINAL $s ==="; tail -8 "$log" 2>/dev/null
done
for pc in $CARDS; do
  p="${pc%%:*}"
  si=$(curl -s -o /dev/null -w "%{http_code}/%{time_total}s" -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$p/server_info")
  gm=$(curl -s -o /dev/null -w "%{http_code}/%{time_total}s" -m 5 -H "Authorization: Bearer $KEY" "http://127.0.0.1:$p/get_model_info")
  echo ":$p si=$si gm=$gm"
done
echo "=== TOP THREADS (spin check) ==="
for pc in $CARDS; do
  c="${pc#*:}"
  MPID=$(docker top "$c" -eo pid,cmd 2>/dev/null | awk "/schedul/ && !/awk/ {print \$1; exit}")
  echo "--- $c mp=$MPID ---"
  [ -n "$MPID" ] && ps -L -o tid,pcpu,comm -p "$MPID" 2>/dev/null | sort -k2 -rn | head -5
done
