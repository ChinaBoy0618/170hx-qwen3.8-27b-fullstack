#!/bin/bash
# 08-start-monitoring.sh — 启动监控栈 (Prometheus + Grafana + exporters)
# 用法: bash scripts/08-start-monitoring.sh
# 前置: 04-build-monitoring.sh 完成
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MON_CONF_DIR="${MONITORING_CONF_DIR:-/mnt/data/observability}"

# 如果监控配置目录不存在，从仓库同步
if [ ! -d "$MON_CONF_DIR" ]; then
  echo "[08] $MON_CONF_DIR not found, syncing from repo..."
  mkdir -p "$MON_CONF_DIR"
  cp -r "$REPO_ROOT/monitoring/prometheus.yml" "$MON_CONF_DIR/"
  cp -r "$REPO_ROOT/monitoring/rules.yml" "$MON_CONF_DIR/"
  cp -r "$REPO_ROOT/monitoring/exporters.py" "$MON_CONF_DIR/"
  cp -r "$REPO_ROOT/monitoring/feishu-watch.py" "$MON_CONF_DIR/"
  cp -r "$REPO_ROOT/monitoring/grafana" "$MON_CONF_DIR/grafana"
  # 创建 grafana-data 目录（dashboard 存储）
  mkdir -p "$MON_CONF_DIR/grafana-data/provisioning/datasources"
  mkdir -p "$MON_CONF_DIR/grafana-data/provisioning/dashboards"
  cp "$REPO_ROOT/monitoring/grafana/provisioning/datasources/ds-prometheus.yml" \
     "$MON_CONF_DIR/grafana-data/provisioning/datasources/" 2>/dev/null || true
  cp "$REPO_ROOT/monitoring/grafana/provisioning/dashboards/pd-760t.yml" \
     "$MON_CONF_DIR/grafana-data/provisioning/dashboards/" 2>/dev/null || true
  cp "$REPO_ROOT/monitoring/grafana/dashboards/sglang-760.json" \
     "$MON_CONF_DIR/grafana-data/provisioning/dashboards/" 2>/dev/null || true
  chmod -R 0777 "$MON_CONF_DIR/grafana-data" 2>/dev/null || true
fi

# 确保 env 文件存在
if [ ! -f "$MON_CONF_DIR/feishu.env" ]; then
  echo "[08] WARNING: $MON_CONF_DIR/feishu.env missing (feishu-watch will not run)"
  echo "# Create feishu.env with:" > "$MON_CONF_DIR/feishu.env"
  echo "FEISHU_WEBHOOK=https://open.feishu.cn/open-apis/bot/v2/hook/YOUR_WEBHOOK_ID" >> "$MON_CONF_DIR/feishu.env"
  chmod 400 "$MON_CONF_DIR/feishu.env"
fi
if [ ! -f "$MON_CONF_DIR/grafana.env" ]; then
  echo "[08] WARNING: $MON_CONF_DIR/grafana.env missing (Grafana will use defaults)"
  echo "GF_SECURITY_ADMIN_USER=admin" > "$MON_CONF_DIR/grafana.env"
  echo "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-changeme}" >> "$MON_CONF_DIR/grafana.env"
  chmod 400 "$MON_CONF_DIR/grafana.env"
fi

echo "=== [08] Starting monitoring stack ==="
bash "$REPO_ROOT/monitoring/launch-observability.sh"

echo "=== [08] Monitoring started ==="
echo "[08] Verify with: bash scripts/verify/v5-monitoring.sh"
