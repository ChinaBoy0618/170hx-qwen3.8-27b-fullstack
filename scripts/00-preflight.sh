#!/bin/bash
# 00-preflight.sh — 部署前置检查（工具链 / 网络 / GPU / 磁盘 / 环境变量）
# 用法: bash scripts/00-preflight.sh
# 幂等: 纯检查, 不产生任何副作用; 全部通过输出 ALL PASS, 否则以非零码退出
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== 00 preflight: toolchain ==="
for tool in docker nvidia-smi python3; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool present"; else bad "$tool missing"; fi
done

echo "=== 00 preflight: docker daemon ==="
if docker info >/dev/null 2>&1; then ok "docker daemon running"; else bad "docker daemon not running"; fi

echo "=== 00 preflight: nvidia-container-toolkit ==="
if docker run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1 \
   || docker info 2>/dev/null | grep -qi 'nvidia'; then
  ok "nvidia runtime available"
else
  bad "nvidia runtime not detected (install nvidia-container-toolkit)"
fi

echo "=== 00 preflight: GPUs ==="
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l | tr -d ' ')
  if [ "$GPU_COUNT" -ge 4 ]; then ok "$GPU_COUNT GPUs detected (need 4)"; else bad "only $GPU_COUNT GPUs (need 4)"; fi
else
  bad "nvidia-smi missing, cannot count GPUs"
fi

echo "=== 00 preflight: disk space ==="
AVAIL_MB=$(df -BG /mnt 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'BG' || echo 0)
if [ "${AVAIL_MB:-0}" -ge 100000 ]; then ok "/mnt free: ${AVAIL_MB}GB (>=100GB)"; else bad "/mnt free: ${AVAIL_MB}MB (<100GB)"; fi

echo "=== 00 preflight: network (base image pulls) ==="
if docker pull lmsysorg/sglang:v0.5.19@sha256:e6238090791a938ab86dd21a9a6394192dad15237e815df557cf83524d54b813 >/dev/null 2>&1 \
   || docker image inspect lmsysorg/sglang:v0.5.19@sha256:e6238090791a938ab86dd21a9a6394192dad15237e815df557cf83524d54b813 >/dev/null 2>&1; then
  ok "sglang base image available"
else
  bad "sglang base image not pullable/present"
fi

echo "=== 00 preflight: required tools (build path) ==="
for tool in patch cargo go node; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool present"; else
    case "$tool" in
      cargo) bad "cargo missing — needed only for gateway rebuild (skip if using prebuilt wheel)";;
      go)    bad "go missing — needed only for new-api go-only rebuild (skip if using prebuilt image)";;
      node)  bad "node missing — needed only for new-api channel scripts (sqlite) (skip if using prebuilt image)";;
      *)     bad "$tool missing";;
    esac
  fi
done

echo "=== 00 preflight: environment variables ==="
: "${SGLANG_API_KEY:?SGLANG_API_KEY not set (see .env.example)}"
ok "SGLANG_API_KEY set"
for var in SGLANG_MODEL_PATH SGLANG_DRAFT_PATH; do
  if [ -n "${!var:-}" ]; then ok "$var set"; else bad "$var not set (see .env.example)"; fi
done

echo ""
echo "=============================="
echo "preflight: PASS=$PASS FAIL=$FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ] && echo "ALL PASS — ready to build" || echo "fix FAIL items before proceeding"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
