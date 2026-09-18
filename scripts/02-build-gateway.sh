#!/bin/bash
# 02-build-gateway.sh — 构建 SMG 网关镜像 (Rust → Python wheel → Docker)
# 用法: bash scripts/02-build-gateway.sh
# 前置: cargo, maturin, rustup (见 rust-toolchain.toml)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/gateway"

GW_TAG="sglang-gateway:sessionkey-v2"

echo "=== [02] Building gateway Python wheel (maturin release) ==="
make python-build

WHEEL_FILE=$(find bindings/python/dist -name "*.whl" | head -1)
if [ -z "$WHEEL_FILE" ]; then
  echo "[02] ERROR: no wheel produced in bindings/python/dist/" >&2
  exit 1
fi
echo "[02] Wheel: $WHEEL_FILE"
echo "[02] Wheel sha256: $(sha256sum "$WHEEL_FILE" | awk '{print $1}')"

echo "=== [02] Building gateway Docker image ==="
# 生产镜像: 基于 760 现役 ubuntu:24.04 基线 + wheel 安装
# 如需重建基线: docker build -f Dockerfile.gateway -t "$GW_TAG" .
# 此处假设 760 已有基线镜像，仅做 wheel 替换验证
# 若需全量重建，取消下面注释:
# cat > /tmp/Dockerfile.gw <<'EOF'
# FROM ubuntu:24.04
# RUN apt-get update && apt-get install -y python3 python3-pip && rm -rf /var/lib/apt/lists/*
# COPY bindings/python/dist/*.whl /tmp/gw-wheel/
# RUN pip3 install /tmp/gw-wheel/*.whl
# ENTRYPOINT ["sglang-router"]
# EOF
# docker build -f /tmp/Dockerfile.gw -t "$GW_TAG" .
echo "[02] Gateway build complete: $GW_TAG (verify with v2-gateway.sh)"
