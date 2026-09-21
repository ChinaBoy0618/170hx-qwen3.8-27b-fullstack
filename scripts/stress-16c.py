#!/usr/bin/env python3
"""16 并发压测 — 直连引擎端口，绕过 SMG（避免 sessionkey 粘滞打到别的卡）。

用法:
  PORT=5803 CONCURRENCY=16 DURATION=7200 python3 scripts/stress-16c.py
环境变量: PORT(必填) / KEY / MODEL / CONCURRENCY / DURATION / LOG
"""
import json, os, time, threading, urllib.request
from concurrent.futures import ThreadPoolExecutor

PORT = int(os.environ.get("PORT", "5803"))
KEY = os.environ.get("KEY", "sk-qwen38-GE0CIlgTQsVLj41laThTVb-6wY2khVtT")
MODEL = os.environ.get("MODEL", "qwen3.8")
URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"
CONCURRENCY = int(os.environ.get("CONCURRENCY", "16"))
DURATION = int(os.environ.get("DURATION", "7200"))
LOG = os.environ.get("LOG", f"/tmp/stress-{PORT}.log")

PROMPTS = [
    "Explain the trade-offs between eventual consistency and strong consistency in distributed systems. Be concise.",
    "Write a detailed technical analysis of the CAP theorem as it applies to a multi-region Kubernetes cluster. Cover: 1) How etcd implements CP under normal operation 2) What happens during a network partition between regions 3) Practical strategies for handling split-brain in service mesh scenarios 4) How to choose RPO/RTO targets for different microservices 5) Case study: what happens when a pod in region B loses quorum for 30 seconds while a write is in-flight.",
    "You are a senior systems architect reviewing a critical design document for a real-time fraud detection pipeline that processes 50,000 transactions per second across 12 data centers. Each transaction passes through 7 microservice stages: ingestion, enrichment, rule-engine, ML-scoring, decision, notification, and audit. The ML scoring stage uses 3 different model ensembles with ensemble voting. Latency budget: p50 < 50ms, p99 < 200ms end-to-end. Provide a thorough multi-paragraph review covering: (1) Architecture - evaluate the synchronous pipeline, identify single points of failure, design graceful degradation when ML scoring degrades to p99 > 500ms, consider circuit breakers, request shedding, fallback scoring; (2) Data Flow - enrichment fetches from 4 external providers with reliability 99.9/99.5/99.99/97 percent, how to handle partial enrichment, should scoring proceed with incomplete features, accuracy vs latency impact; (3) Scalability - at 4167 tps per DC, rule engine is CPU-bound 2ms per transaction, ML scoring is GPU-bound with 8 A100 GPUs per DC, calculate whether 8 GPUs handle scoring at 500 inferences per second each with 3 models per transaction, identify the bottleneck, propose scaling; (4) Consistency - audit logs must be exactly-once via Kafka idempotent producers, notification retries on timeout, explain consistency implications, propose saga-based compensation; (5) Observability - top 5 SLOs, golden signals, distributed tracing across 7 services under 5 percent overhead, error budget policy and page thresholds; (6) Security - API key rotation, model serving endpoints, cross-DC data transfer, audit log integrity under zero-trust; (7) Cost - annual infrastructure 4.2M USD, ML scoring 1.8M USD 43 percent, propose 3 cost-optimization strategies with savings and risk. Provide priority-ordered recommendations P0/P1/P2 with estimated effort.",
]
MAXTS = [512, 1024, 2048, 4096]

lock = threading.Lock()
stats = {"ok": 0, "fail": 0, "total": 0}


def fire(batch, j, idx):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPTS[idx % len(PROMPTS)]}],
        "max_tokens": MAXTS[idx % len(MAXTS)],
    }).encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    t0 = time.time()
    code = 0
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            code = r.getcode()
    except Exception as e:
        code = 0
        if hasattr(e, "code"):
            code = e.code
    dt = int((time.time() - t0) * 1000)
    with lock:
        stats["total"] += 1
        if code == 200:
            stats["ok"] += 1
        else:
            stats["fail"] += 1
        line = f"{time.strftime('%H:%M:%S')} b={batch} r={j} maxt={MAXTS[idx % len(MAXTS)]} http={code} {dt}ms"
        with open(LOG, "a") as f:
            f.write(line + "\n")
    return code


def main():
    end = time.time() + DURATION
    batch = 0
    with open(LOG, "w") as f:
        f.write(f"=== stress-{PORT} started {time.strftime('%F %T')} concurrency={CONCURRENCY} duration={DURATION}s ===\n")
    with ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
        while time.time() < end:
            b0 = time.time()
            futs = []
            for j in range(1, CONCURRENCY + 1):
                idx = (batch * CONCURRENCY + j) % 12  # 轮转 prompt/maxt 组合
                futs.append(ex.submit(fire, batch, j, idx))
            for fu in futs:
                fu.result()
            ok, fl, tot = stats["ok"], stats["fail"], stats["total"]
            rate = ok * 100 // tot if tot else 0
            with open(LOG, "a") as f:
                f.write(f"{time.strftime('%H:%M:%S')} batch={batch} ok={ok} fail={fl} rate={rate}% batch_wall={int(time.time()-b0)}s\n")
            batch += 1
            wait = 1.0 - (time.time() - b0)
            if wait > 0:
                time.sleep(wait)
    with open(LOG, "a") as f:
        f.write(f"{time.strftime('%F %T')} stress-{PORT} complete: total={stats['total']} ok={stats['ok']} fail={stats['fail']}\n")


main()
