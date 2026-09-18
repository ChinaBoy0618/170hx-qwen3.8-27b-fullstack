#!/bin/bash
# 04-build-monitoring.sh — 拉取/验证监控栈镜像
# 用法: bash scripts/04-build-monitoring.sh
# 说明: 监控栈使用标准镜像 (prometheus/grafana/node-exporter/python)，无需 build
set -euo pipefail

echo "=== [04] Pulling monitoring images ==="
docker pull prom/prometheus:latest || echo "[04] WARNING: prometheus pull failed (may be cached)"
docker pull prom/node-exporter:latest || echo "[04] WARNING: node-exporter pull failed (may be cached)"
docker pull grafana/grafana:13.2.1 || echo "[04] WARNING: grafana pull failed (may be cached)"
docker pull python:3.12-slim || echo "[04] WARNING: python pull failed (may be cached)"

echo "=== [04] Verifying images present ==="
for img in prom/prometheus:latest prom/node-exporter:latest grafana/grafana:13.2.1 python:3.12-slim; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "  [OK] $img"
  else
    echo "  [FAIL] $img missing"
    exit 1
  fi
done

echo "[04] DONE — all monitoring images available"
