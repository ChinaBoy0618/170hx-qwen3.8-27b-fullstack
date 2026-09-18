#!/bin/bash
# 03-build-newapi.sh — 构建 new-api 镜像
# 用法: bash scripts/03-build-newapi.sh
# 前置: docker (go 工具链在 Dockerfile 内)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/new-api"

NAPI_TAG="new-api:fixtoolidx-0831-full"

echo "=== [03] Building new-api image ==="
# 全量构建 (web + go):
docker build -f Dockerfile -t "$NAPI_TAG" .
# 或仅 go-only 快速路径 (需已有 web/dist):
# docker build -f Dockerfile.go-only -t "$NAPI_TAG" .

echo "[03] DONE — image: $NAPI_TAG"
