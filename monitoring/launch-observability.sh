#!/usr/bin/env bash
# 760T 可观测容器拉起（幂等）。host 网络、--restart unless-stopped、web 绑 loopback。
set -euo pipefail
CONF_DIR=/mnt/data/observability

up_container() {  # $1=name $2=image $3...=image+args 之后的参数
  local name="$1"; shift
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --network host --restart unless-stopped "$@"
}

# Prometheus（web 127.0.0.1:9090，配置与规则挂入）
up_container 760-prometheus \
  -v "$CONF_DIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
  -v "$CONF_DIR/rules.yml:/etc/prometheus/rules.yml:ro" \
  -v "$CONF_DIR/prom-data:/prom" \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prom \
  --storage.tsdb.retention.time=7d \
  --web.listen-address=127.0.0.1:9090

# node-exporter（loopback 9100，宿主 / 挂 /host 供 /proc /sys 读取）
up_container 760-node-exporter \
  -v /:/host:ro \
  prom/node-exporter:latest \
  --web.listen-address=127.0.0.1:9100 \
  --path.rootfs=/host

# 合并 exporter (单进程两端口):
#   :19011 JSON 桥 (new-api /api/perf-metrics/summary -> Prometheus 文本, 拉模式)
#   :19012 GPU 硬件 (nvidia-smi 5s 轮询 -> 温度/功耗/利用率/显存/时钟)
# 需 nvidia runtime(宿主机有 nvidia-container-toolkit, 注入 nvidia-smi+驱动库, 无需特权);
# 无状态, 挂了重建即可
docker rm -f 760-exporters >/dev/null 2>&1 || true
docker run -d --name 760-exporters --network host --restart unless-stopped \
  --runtime nvidia -e NVIDIA_VISIBLE_DEVICES=all \
  -v "$CONF_DIR/exporters.py:/opt/exp/exporters.py:ro" \
  python:3.12-slim python3 /opt/exp/exporters.py

# Grafana（web 127.0.0.1:3000，数据源+dashboard 由 grafana-data/ 内 provisioning 驱动）
# 凭据在 grafana.env（chmod 400，与 feishu.env 同姿态），不落脚本明文
# 容器内 grafana 进程 uid=472，而宿主挂载目录属主是 1000(i)，非 root 无法 chown，
# 只能 chmod 放权让 472 可写（幂等）
chmod -R 0777 "$CONF_DIR/grafana-data" 2>/dev/null || true
up_container 760-grafana \
  -v "$CONF_DIR/grafana-data:/var/lib/grafana" \
  -v "$CONF_DIR/grafana-data/provisioning/datasources/ds-prometheus.yml:/etc/grafana/provisioning/datasources/ds-prometheus.yml:ro" \
  -v "$CONF_DIR/grafana-data/provisioning/dashboards/pd-760t.yml:/etc/grafana/provisioning/dashboards/pd-760t.yml:ro" \
  --env-file "$CONF_DIR/grafana.env" \
  -e GF_SERVER_HTTP_ADDR=127.0.0.1 \
  -e GF_SERVER_HTTP_PORT=3000 \
  -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -e GF_ANALYTICS_CHECK_FOR_UPDATES=false \
  grafana/grafana:13.2.1

echo "=== containers ==="
for c in 760-prometheus 760-node-exporter 760-grafana 760-exporters; do
  docker ps --filter "name=^${c}\$" --format "{{.Names}} {{.Status}}"
done
echo "=== targets (9090) ==="
sleep 4
curl -s 127.0.0.1:9090/api/v1/targets 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);[print(t["labels"].get("job"),t["scrapeUrl"],t["health"]) for t in d["data"]["activeTargets"]]' 2>/dev/null \
  || echo "(targets not ready yet)"
