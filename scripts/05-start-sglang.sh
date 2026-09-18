#!/bin/bash
# 05-start-sglang.sh — 启动 4 卡 SGLang 推理实例
# 用法: bash scripts/05-start-sglang.sh
# 前置: 01-build-sglang.sh 完成; SGLANG_API_KEY, SGLANG_MODEL_PATH, SGLANG_DRAFT_PATH 已设
# 幂等: 已有同名容器先删再建
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/.env" 2>/dev/null || echo "[05] WARNING: .env not found, relying on exported env"

# 确保关键变量已设
: "${SGLANG_API_KEY:?SGLANG_API_KEY not set}"
: "${SGLANG_MODEL_PATH:?SGLANG_MODEL_PATH not set}"
: "${SGLANG_DRAFT_PATH:?SGLANG_DRAFT_PATH not set}"

SGLANG_IMG="${SGLANG_IMG:-sglang:dflash2-ttl-tier4-tclook-0917}"
BASE_PORT="${SGLANG_BASE_PORT:-5800}"
SGLANG_CTX_LEN="${SGLANG_CTX_LEN:-262144}"
SGLANG_HICACHE_RATIO="${SGLANG_HICACHE_RATIO:-1.0}"
SGLANG_CHUNK_PREFILL="${SGLANG_CHUNK_PREFILL:-8192}"
SGLANG_MEM_FRACTION="${SGLANG_MEM_FRACTION:-0.9}"
WARM_CC="${WARM_CC:-1}"
L3_DIR_BASE="${SGLANG_L3_DIR_BASE:-/mnt/nvme-kv/kv-l3}"

echo "=== [05] Starting 4 SGLang instances (image=$SGLANG_IMG) ==="

for gpu in 0 1 2 3; do
  PORT=$((BASE_PORT + gpu))
  CONTAINER_NAME="qwen38-27b-gpu${gpu}"
  # gpu0 用特殊名称与生产保持一致
  [ "$gpu" = "0" ] && CONTAINER_NAME="qwen38-27b"

  echo "--- Starting $CONTAINER_NAME (GPU $gpu, port $PORT) ---"

  export SGLANG_IMG="$SGLANG_IMG"
  export SGLANG_L3_DIR="${L3_DIR_BASE}/gpu${gpu}"
  export SGLANG_L3_MAX_GB="${SGLANG_L3_MAX_GB:-100G}"
  export WARM_CC="$WARM_CC"

  bash "$REPO_ROOT/sglang/launch-awq.sh" "$CONTAINER_NAME" "$gpu" "$PORT" qwen3.8

  echo "[05] $CONTAINER_NAME launched on :$PORT"
  unset SGLANG_L3_DIR SGLANG_L3_MAX_GB
done

echo "=== [05] All 4 SGLang instances started ==="
echo "[05] Verify with: bash scripts/verify/v1-sglang.sh"
