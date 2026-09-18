# TUNING.md — 参数调优依据（唯一出处）

> 本文件回答**为什么**采用当前这组参数，以及各 canary 的数据支撑。
> 任何参数变更须先在此登记 rationale + canary 数据，再改生产。

---

## 一、SGLang 推理引擎

### 1.1 铁律（禁改）

| 参数 | 值 | 依据 |
|---|---|---|
| `--context-length` | 262144 | 用户白名单，改动需显式授权 |
| `--mem-fraction-static` | 0.9 | 0.92 曾打爆 3 卡 OOM；0.9 为安全上限 |
| `--speculative-algorithm` | DFLASH | 0913 canary：MTP 比 DFLASH 慢 6~19%，不切 |
| `--speculative-num-draft-tokens` | 8 | = DFlash2 `block_size=8`；调大需重训 draft |
| `--kv-cache-dtype` | fp8_e4m3 | 0912 canary：fp8 KV 吞吐优于 bf16 KV，省显存 |
| `--enable-hierarchical-cache` | on | 分级 KV 核心 |
| `--hicache-ratio` | 1.0 | 0916 判决：1.5 扩容被 RAM 硬约束（256 GB 宿主）否决 |
| GPU power limit | 200 W | 硬件安全约束 |
| `--max-running-requests` | 8 | 0912 canary：8 为拐点，>8 无吞吐收益 |

### 1.2 已定型（有 canary 数据）

| 参数 | 值 | 依据 |
|---|---|---|
| `--chunked-prefill-size` | 8192 | 0913 canary：4096→8192 吞吐提升；8192 为最优点 |
| `--cuda-graph-max-bs` | 16 | 配合 max-running-requests=8 |
| `--radix-eviction-policy` | ttl_watermark | 0001-0005 补丁链核心 |
| `--disable-prefill-cuda-graph` | on | 0913：修 prefill 截断 bug |
| `--tokenizer-worker-num` | 4 | 0911 tkw-auth 补丁支持多 worker |
| `--enable-cache-report` | on | 监控必需 |
| `--reasoning-parser` | qwen3 | 模型固定 |
| `--tool-call-parser` | qwen3_coder | 模型固定 |
| `--chat-template` | /chat-template-fix.jinja | 修 tool_reference 字段 |
| `--max-mamba-cache-size` | 32 | mamba 状态池 |
| `--mamba-ssm-dtype` | bfloat16 | 与主模型 dtype 对齐 |
| `--hicache-write-policy` | write_through | 0912 起双暖 → tier2 依赖 write_through 落 host |
| `--enable-metrics` | on | Prometheus 抓取 |

### 1.3 CPU 分区（cpuset）

| GPU | cpuset | 说明 |
|---|---|---|
| gpu0 | 0-1,10-11 | 4 逻辑线程 = 2 物理核 + HT |
| gpu1 | 2-3,12-13 | |
| gpu2 | 4-5,14-15 | |
| gpu3 (main) | 6-7,16-17 | |
| 宿主保留 | 8,9,18,19 | 网关/监控/dify/comfyui/frpc |

### 1.4 容器 env（与 cpuset 对齐）

| 变量 | 值 | 说明 |
|---|---|---|
| `OMP_NUM_THREADS` | 4 | 匹配 cpuset 核数 |
| `OPENBLAS_NUM_THREADS` | 4 | |
| `MKL_NUM_THREADS` | 4 | |
| `VECLIB_MAXIMUM_THREADS` | 1 | |
| `TOKENIZERS_PARALLELISM` | FALSE | 防重复 fork |
| `SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK` | 1 | 跳 decode lock |
| `PYTORCH_CUDA_ALLOC_CONF` | expandable_segments:True | 防 OOM 碎片 |
| `HF_HUB_OFFLINE` / `TRANSFORMERS_OFFLINE` | 1 | 离线 |
| `AWQ_SGLANG_VIDEO_DECODER` | decord | 视频解码器 |

### 1.5 CC 前缀双暖 + tier4 pin

- **载荷**：纯 system + tools（20 144 tok），无 session user（09-13 裁减）
- **双暖原理**：
  - pass1：建枝，hit_count=1，write_through 已落 host
  - pass2：复用同枝，hit_count=2 → ttl_watermark 自动晋升 **tier2**（L1 共享前缀，最后被逐）+ 12 h TTL
  - 单暖只到 tier1（压力下先被逐）；双暖才拿到"最后淘汰 + 12 h"
- **pin**：`POST /admin/pin_prefix` → tier4 永久钉住，evictable 从 20 191 → 63
- **效果**：新会话首 turn 命中 99.8-99.9%，TTFT 15 s → 0.42 s
- **失败不阻断**：launch-awq.sh 内双暖 + pin 均 try/catch，失败仅打印警告

### 1.6 L3 文件缓存（可选）

- `SGLANG_L3=1`（默认开启）；`SGLANG_L3=0` 关闭
- 路径：`/mnt/nvme-kv/kv-l3/gpu{0..3}`，每卡上限 100 GB
- 09-03 判决曾关；09-13 重开（NVMe 空间充足后）

---

## 二、SMG 网关

| 参数 | 值 | 依据 |
|---|---|---|
| `--policy` | manual | sessionkey-v2：手动路由 |
| `--assignment-mode` | min_load | 无 session key 时按最小 load |
| `--routing-map-file` | /mnt/gw-data/session-routing.json | 会话粘滞持久化 |
| 路由 key 优先级 | x-smg-routing-key > x-claude-code-session-id > c:xxh3(前8192) > min_load | 09-17 sessionkey-v2 设计 |
| `--health-check-endpoint` | /get_model_info | 09-10 A3：底延迟 5 ms，不阻塞探活 |
| `--health-check-timeout-secs` | 3 | 端点 5 ms，3 s 余量充足 |
| `--health-failure-threshold` | 3 | 09-10 cb-relax：防 busy 卡被误摘 |
| `--health-success-threshold` | 1 | 恢复秒级 |
| `--cb-failure-threshold` | 10 | 09-10 cb-relax：防长 prefill 误杀 |
| `--cb-timeout-duration-secs` | 60 | 09-10 cb-relax |
| `--request-timeout-secs` | 600 | 硬上限；smg 默认 1800 过长 |
| `--retry-max-retries` | 2 | |
| 路由表快照 | 60 s 原子写，4 h TTL | sessionkey-v2 设计 |

**09-09 教训**：`/health` 底延迟恒 ~1 s（dummy generate）+ 长 prefill 期间顶到 8-15 s，旧路由超时 5 s + 连续 2 败即摘 → busy 卡被误踢（09-09 08:34 UTC :5800 14 连败掉线实证）。修复：换端点 + 放宽阈值。

---

## 三、可改参数（有优化空间，需 canary）

| 参数 | 当前值 | 潜在方向 | 风险 |
|---|---|---|---|
| `triton_attention_num_kv_splits` | 8（默认） | 长上下文 decode 可调 | 低 |
| `enable_fused_qk_norm_rope` | False（默认） | 可测融合 QK norm + RoPE | 低 |
| `kv_canary` | none | 'log' 可开（免费） | 极低 |
| `num_continuous_decode_steps` | 1 | 连续 decode 步数 | 中 |
| `enable_mixed_chunk` | False | 混合 chunk | 中 |
| `prefill_decode_interval` | 0 | 纯交织 | 中 |

> 详见 `docs/760-SGLang启动参数全量分析-20260912.md` Part 2。

---

## 四、Canary 数据引用

| 日期 | Canary | 结论 |
|---|---|---|
| 09-11 | 50 轮工具测试 | DFLASH 稳定，无泄漏 |
| 09-12 | 6 项 flag canary | triton splits = inert；chunk 8192 = 起服崩→修；fused-qk = 无增益；draft-window 8192 = accept 塌；kv-canary = 崩；triton 后端切换（被迫 e5m2）= accept 4.6→2.7 破门禁 |
| 09-12 | AWQ 四卡切换 | KV 池 +58.4%（416 122 → 659 346/卡） |
| 09-12 | W4A4 / W4A8 调研 | W4A4 可跑但慢 5~12%；W4A8 全要 FP8 TC，上不了 sm_80 |
| 09-13 | MTP vs DFLASH | MTP 慢 6~19%，不切 |
| 09-13 | chunk 8192 + disable-prefill-cuda-graph | 修截断 bug，四卡全滚 |
| 09-15 | NInfer cmp170hx | 非生产平替，受控仅 51.7 smoke |
| 09-15 | 409 榜单溯源 | 409 不可达，SGLang 生产全面胜 vLLM |
| 09-16 | ratio 1.5 扩容 | RAM 硬约束，被否 |
| 09-17 | tc-lookahead | thinking 内工具标签泄漏修复，四卡全滚 |
