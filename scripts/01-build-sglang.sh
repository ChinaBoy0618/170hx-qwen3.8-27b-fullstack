#!/bin/bash
# 01-build-sglang.sh — 构建 SGLang 基础镜像 + 生产镜像
# 用法: bash scripts/01-build-sglang.sh
# 前置: 00-preflight.sh 已通过
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SGLANG_BASE_TAG="sglang:dflash2-fullstack-base"
SGLANG_PROD_TAG="sglang:dflash2-fullstack"

echo "=== [01] Building SGLang base image (v0.5.19 + patches 0001-0005) ==="
docker build -f sglang/Dockerfile.base -t "$SGLANG_BASE_TAG" .
echo "[01] Base image built: $SGLANG_BASE_TAG"

echo "=== [01] Building SGLang prod image (base + 0006 tc-lookahead) ==="
docker build -f sglang/Dockerfile.prod -t "$SGLANG_PROD_TAG" .
echo "[01] Prod image built: $SGLANG_PROD_TAG"

echo "=== [01] Tag as production alias (matches 760 live tag) ==="
docker tag "$SGLANG_PROD_TAG" "sglang:dflash2-ttl-tier4-tclook-0917"
echo "[01] DONE — image ready: sglang:dflash2-ttl-tier4-tclook-0917"
