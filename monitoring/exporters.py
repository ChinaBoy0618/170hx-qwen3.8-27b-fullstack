#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""760T 合并 exporter: 单进程两端口。
:19011 JSON 桥 (new-api /api/perf-metrics/summary -> Prometheus 文本, 拉模式)
:19012 GPU 硬件 (nvidia-smi 5s 轮询缓存 -> 温度/功耗/利用率/显存/时钟)
无状态, 挂了重建即可; GPU 侧 nvidia-smi 挂 -> nvidia_up=0。
"""
import json
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TIMEOUT = 4
POLL_S = 5


def fnum(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def render(parts):
    """Prometheus 文本: parts=[(typ, mname, help, labels, val)]"""
    seen, lines = set(), []
    for typ, mname, help, lab, val in parts:
        if mname not in seen:
            seen.add(mname)
            lines.append("# HELP %s %s" % (mname, help))
            lines.append("# TYPE %s %s" % (mname, typ))
        lines.append("%s%s %s" % (mname, lab, format(val, ".10g")))
    return ("\n".join(lines) + "\n").encode("utf-8")


def send_metrics(handler, body):
    handler.send_response(200)
    handler.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class MetricsHandler(BaseHTTPRequestHandler):
    RENDER = None  # 子类设置: () -> bytes

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.split("?")[0] != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        send_metrics(self, self.RENDER())


# ---------------- JSON 桥 (:19011) ----------------

def http_json(url):
    with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


def build_newapi(d):
    out = []
    for mo in (d.get("data") or {}).get("models", []):
        name = str(mo.get("model_name", "?")).replace('"', "").replace("\n", " ")
        lab = '{model="%s"}' % name
        out.append(("gauge", "newapi_model_avg_latency_ms", "new-api 模型平均延迟 (ms)", lab,
                    fnum(mo.get("avg_latency_ms"))))
        out.append(("gauge", "newapi_model_success_rate", "new-api 模型成功率 (%)", lab,
                    fnum(mo.get("success_rate"))))
        out.append(("gauge", "newapi_model_avg_tps", "new-api 模型平均 TPS", lab,
                    fnum(mo.get("avg_tps"))))
    return out


JSON_SOURCES = [
    ("newapi", "http://127.0.0.1:3001/api/perf-metrics/summary", build_newapi),
]


def json_render():
    parts = []
    for name, url, build in JSON_SOURCES:
        try:
            parts.extend(build(http_json(url)))
            parts.append(("gauge", "%s_up" % name, "%s 指标端点可达 (1/0)" % name, "", 1.0))
        except Exception:
            parts.append(("gauge", "%s_up" % name, "%s 指标端点可达 (1/0)" % name, "", 0.0))
    # 告警桥: Prometheus 3.14 取消了 alerts 指标, 状态只在 /api/v1/alerts
    # -> prom_alerts{state,alertname,component,severity}(1=pending/firing), 面板查它
    try:
        parts.extend(build_alerts(http_json("http://127.0.0.1:9090/api/v1/alerts")))
        parts.append(("gauge", "prom_alerts_up", "Prometheus alerts 端点可达 (1/0)", "", 1.0))
    except Exception:
        parts.append(("gauge", "prom_alerts_up", "Prometheus alerts 端点可达 (1/0)", "", 0.0))
    return render(parts)


def build_alerts(d):
    out = []
    for a in (d.get("data") or {}).get("alerts", []):
        lab = a.get("labels") or {}
        name = str(lab.get("alertname", "?")).replace('"', "")
        comp = str(lab.get("component", "unknown")).replace('"', "")
        sev = str(lab.get("severity", "none")).replace('"', "")
        inst = str(lab.get("instance", lab.get("worker", ""))).replace('"', "")
        state = str(a.get("state", "unknown")).replace('"', "")
        out.append(("gauge", "prom_alerts", "告警状态 (1=pending/firing, 0 无此告警)",
                    '{state="%s",alertname="%s",component="%s",severity="%s",instance="%s"}'
                    % (state, name, comp, sev, inst), 1.0))
    return out


class JsonHandler(MetricsHandler):
    RENDER = staticmethod(json_render)


# ---------------- GPU (:19012) ----------------

GPU_FIELDS = "index,temperature.gpu,power.draw,power.limit,utilization.gpu," \
            "utilization.memory,memory.used,memory.total,clocks.sm,clocks.max.sm"
GPU_QUERY = ["nvidia-smi", "--query-gpu=" + GPU_FIELDS, "--format=csv,noheader,nounits"]


def gpu_poll():
    """一次 nvidia-smi 查询 -> 每卡 dict 列表; 失败返回 None。"""
    try:
        out = subprocess.run(GPU_QUERY, capture_output=True, text=True, timeout=10)
        if out.returncode != 0:
            return None
    except Exception:
        return None
    cards = []
    for line in out.stdout.strip().splitlines():
        p = [x.strip() for x in line.split(",")]
        if len(p) != 10:
            continue
        cards.append({
            "gpu": p[0],
            "temp_c": fnum(p[1]),
            "power_w": fnum(p[2]),
            "power_limit_w": fnum(p[3]),
            "util_pct": fnum(p[4]),
            "mem_util_pct": fnum(p[5]),
            "mem_used_bytes": fnum(p[6]) * 1024 * 1024,
            "mem_total_bytes": fnum(p[7]) * 1024 * 1024,
            "sm_clock_mhz": fnum(p[8]),
            "max_sm_clock_mhz": fnum(p[9]),
        })
    return cards or None


class GpuCache:
    def __init__(self):
        self.lock = threading.Lock()
        self.cards = None
        self.ok = False

    def worker(self):
        while True:
            cards = gpu_poll()
            with self.lock:
                self.cards, self.ok = cards, cards is not None
            time.sleep(POLL_S)

    def parts(self):
        with self.lock:
            ok, cards = self.ok, (self.cards or [])
        parts = [("gauge", "nvidia_up", "nvidia-smi 轮询成功 (1/0)", "", 1 if ok else 0)]
        if not ok:
            return parts
        m = [
            ("nvidia_gpu_temperature_c", "GPU 温度 (C)", "temp_c"),
            ("nvidia_gpu_power_w", "GPU 功耗 (W)", "power_w"),
            ("nvidia_gpu_power_limit_w", "GPU 功耗 cap (W)", "power_limit_w"),
            ("nvidia_gpu_utilization_pct", "GPU 计算利用率 (%)", "util_pct"),
            ("nvidia_gpu_memory_utilization_pct", "GPU 显存带宽利用率 (%)", "mem_util_pct"),
            ("nvidia_gpu_memory_used_bytes", "显存已用 (bytes)", "mem_used_bytes"),
            ("nvidia_gpu_memory_total_bytes", "显存总量 (bytes)", "mem_total_bytes"),
            ("nvidia_gpu_sm_clock_mhz", "SM 当前时钟 (MHz)", "sm_clock_mhz"),
            ("nvidia_gpu_max_sm_clock_mhz", "SM 最大时钟 (MHz)", "max_sm_clock_mhz"),
        ]
        for name, help, key in m:
            for c in cards:
                parts.append(("gauge", name, help, '{gpu="%s"}' % c["gpu"], c[key]))
        return parts


GPU_CACHE = GpuCache()


def gpu_render():
    return render(GPU_CACHE.parts())


class GpuHandler(MetricsHandler):
    RENDER = staticmethod(gpu_render)


if __name__ == "__main__":
    threading.Thread(target=GPU_CACHE.worker, daemon=True).start()
    threading.Thread(
        target=lambda: ThreadingHTTPServer(("127.0.0.1", 19011), JsonHandler).serve_forever(),
        daemon=True).start()
    print("exporters: json-bridge on :19011, gpu on :19012", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 19012), GpuHandler).serve_forever()
