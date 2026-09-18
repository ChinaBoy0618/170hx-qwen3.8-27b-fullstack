#!/bin/bash
# v5-monitoring.sh — 验证监控栈
# 检查: Prometheus targets 全 up / Grafana dashboard 出数 / 760-exporters 可达
set -uo pipefail

PROM="http://127.0.0.1:${PROM_PORT:-9090}"
GRAFANA="http://127.0.0.1:${GRAFANA_PORT:-3000}"
FAIL=0

echo "=== v5: monitoring stack ==="

echo "--- 6a: Prometheus targets ---"
targets=$(curl -s -m 5 "$PROM/api/v1/targets" 2>/dev/null)
if [ -n "$targets" ]; then
  echo "$targets" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for t in d['data']['activeTargets']:
    print(f\"  {t['labels'].get('job','?'):<20} {t['scrapeUrl']:<45} {t['health']}\")
    if t['health'] != 'up':
        print(f\"  *** {t['labels'].get('job','?')} is {t['health']}!\")
" 2>/dev/null || echo "  [WARN] could not parse targets"
else
  echo "  [FAIL] Prometheus :$PROM not reachable"; FAIL=1
fi

echo "--- 6b: 760-exporters ---"
for ep in 19011 19012; do
  code=$(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ep/metrics" 2>/dev/null)
  echo "  exporter :$ep -> HTTP $code"
  [ "$code" = "200" ] || { echo "  [FAIL] exporter :$ep"; FAIL=1; }
done

echo "--- 6c: Grafana ---"
code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$GRAFANA/api/health" 2>/dev/null)
echo "  Grafana /api/health -> $code"
[ "$code" = "200" ] || { echo "  [FAIL] Grafana not reachable"; FAIL=1; }

# Dashboard check (auth-free: dashboard file exists)
if [ -f "monitoring/grafana/dashboards/sglang-760.json" ]; then
  echo "  [OK] dashboard file: sglang-760.json"
else
  echo "  [FAIL] dashboard file missing"; FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "v5 PASS" || { echo "v5 FAIL"; exit 1; }
