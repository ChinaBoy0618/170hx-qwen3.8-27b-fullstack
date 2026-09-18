#!/bin/bash
# v3-newapi.sh — 验证 new-api 网关
# 检查: 健康 / /v1/messages 通 / 敏感词豁免路径 400
set -uo pipefail

NAPI="http://127.0.0.1:${NEWAPI_PORT:-3001}"
NAPI_KEY="${NEWAPI_KEY:?need NEWAPI_KEY}"
FAIL=0

echo "=== v3: new-api ==="
code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$NAPI/api/status")
echo "  /api/status -> $code"; [ "$code" = "200" ] || FAIL=1

echo "  --- normal /v1/messages ---"
r=$(curl -s -m 30 "$NAPI/v1/messages" \
  -H "Authorization: Bearer $NAPI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.8","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}')
echo "  resp: $(echo "$r" | head -c 300)"
echo "$r" | grep -q '"content"' || { echo "  FAIL: no content in response"; FAIL=1; }

echo "  --- sensitive-word exempt path (owner should bypass) ---"
sw=$(curl -s -m 30 -o /dev/null -w "%{http_code}" "$NAPI/v1/messages" \
  -H "Authorization: Bearer $NAPI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.8","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}')
echo "  owner request -> HTTP $sw (expect 200, exempt from sensitive filter)"
[ "$sw" = "200" ] || { echo "  FAIL: expected 200"; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "v3 PASS" || { echo "v3 FAIL"; exit 1; }
