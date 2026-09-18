#!/bin/bash
# 07-start-newapi.sh — 启动 new-api 容器
# 用法: bash scripts/07-start-newapi.sh
# 前置: 03-build-newapi.sh 完成
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/new-api"

NAPI_PORT="${NEWAPI_PORT:-3001}"

echo "=== [07] Starting new-api (port $NAPI_PORT) ==="

NAME=new-api \
PORT=$NAPI_PORT \
bash run-newapi.sh start

echo "=== [07] new-api started ==="
echo "[07] Verify with: bash scripts/verify/v3-newapi.sh"
