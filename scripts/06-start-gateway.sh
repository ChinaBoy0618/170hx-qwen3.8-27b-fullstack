#!/bin/bash
# 06-start-gateway.sh — 启动 SMG 网关 (sessionkey-v2)
# 用法: bash scripts/06-start-gateway.sh
# 前置: 05-start-sglang.sh 完成 (worker 端口 5800-5803 已就绪)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/gateway"

GW_PORT="${GATEWAY_PORT:-30010}"
PROM_PORT="${GATEWAY_PROM_PORT:-29010}"
SGLANG_API_KEY="${SGLANG_API_KEY:?SGLANG_API_KEY not set}"

echo "=== [06] Starting SMG gateway (sessionkey-v2, port $GW_PORT) ==="

# 使用仓库内 run-router.sh（已包含 sessionkey-v2 配置）
NAME=sglang-gateway \
PORT=$GW_PORT \
PROM_PORT=$PROM_PORT \
bash run-router.sh start

echo "=== [06] Gateway started ==="
echo "[06] Verify with: bash scripts/verify/v2-gateway.sh"
