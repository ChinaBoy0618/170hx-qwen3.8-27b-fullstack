#!/bin/bash
# v1-sglang.sh — 验证 4 卡 SGLang 推理层
# 检查: 容器存活 /health / 最小 chat 通 / nvidia-smi 4 卡满载 / DFLASH 生效
set -uo pipefail

KEY="${SGLANG_API_KEY:?need SGLANG_API_KEY}"
BASES=(http://127.0.0.1:5800 http://127.0.0.1:5801 http://127.0.0.1:5802 http://127.0.0.1:5803)
FAIL=0

echo "=== v1: SGLang 4 卡 ==="
for b in "${BASES[@]}"; do
  h=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$b/health")
  echo "  $b /health -> $h"
  [ "$h" = "200" ] || FAIL=1

  r=$(curl -s -m 60 "$b/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"model":"qwen3.8","messages":[{"role":"user","content":"ping"}],"max_tokens":8}')
  echo "  chat: $(echo "$r" | head -c 200)"
  echo "$r" | grep -q '"content"' || FAIL=1

  info=$(curl -s -m 10 "$b/get_model_info" -H "Authorization: Bearer $KEY" 2>/dev/null || true)
  echo "  model_info(spec 应为 DFLASH): $(echo "$info" | head -c 300)"
done

echo "  --- nvidia-smi (期望 4 卡满载) ---"
nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader || FAIL=1

[ "$FAIL" -eq 0 ] && echo "v1 PASS" || { echo "v1 FAIL"; exit 1; }
