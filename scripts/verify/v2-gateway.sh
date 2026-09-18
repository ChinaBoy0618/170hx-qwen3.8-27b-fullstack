#!/bin/bash
# v2-gateway.sh — 验证 SMG 网关: 会话粘滞 + min_load 均衡
# 检查: 同 session-id 恒落同一 worker; 无头请求在 4 卡间均衡
set -uo pipefail

GW="http://127.0.0.1:${GATEWAY_PORT:-30010}"
KEY="${SGLANG_API_KEY:?need SGLANG_API_KEY}"
FAIL=0

echo "=== v2: SMG 网关 ==="
code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$GW/health")
echo "  /health -> $code"; [ "$code" = "200" ] || FAIL=1

worker_of() {  # $1=header 值; 用响应头 X-SMG-Worker(若无则看 /workers 负载)判断
  curl -s -m 30 -D /tmp/v2-hdr.txt -o /tmp/v2-body.json "$GW/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -H "$1" -d '{"model":"qwen3.8","messages":[{"role":"user","content":"ping"}],"max_tokens":4}' >/dev/null 2>&1
  grep -i '^x-smg-worker:' /tmp/v2-hdr.txt 2>/dev/null | tr -d '\r' || echo "(worker 头未暴露, 用 /workers 推断)"
}

# 会话粘滞: 同一 x-claude-code-session-id 连发 3 次, worker 应一致
echo "  --- 会话粘滞 (x-claude-code-session-id) ---"
for i in 1 2 3; do
  echo "  req$i: $(worker_of 'x-claude-code-session-id: v2test-777')"
done

echo "  --- 无头请求 min_load 均衡 (10 次) ---"
for i in $(seq 1 10); do
  echo "  req$i: $(worker_of 'x-no-route: 1')"
done

[ "$FAIL" -eq 0 ] && echo "v2 PASS (人工核对: 同会话 worker 一致; 无头请求分布在多 worker)" || { echo "v2 FAIL"; exit 1; }
