# 170HX-Qwen3.8-27B-fullstack

760 盒子（4× 170HX GPU, sm_80, 64 GB/卡, 宿主 256 GB RAM）上 Qwen3.8-27B 推理全栈的**可复现部署仓库**。

> 本仓库是**交付物**：所有文件均为生产 760 活体的只读快照 + 必要的构建/启动脚本，**不是**上游项目。
> 构建产物与 760 现役镜像逐文件 md5 对齐（见 `BASELINE.md`）。

---

## 一、架构拓扑

```
                       公网入口
                        │
                   ┌────┴────┐
                   │ nginx :443│  (阿里云盒出口)
                   └────┬────┘
                        │ frp 隧道
                        ▼
              ┌──────────────────────┐
              │  760 宿主 256 GB RAM  │
              │  4× 170HX 64 GB      │
              │                      │
              │  ┌────────────────┐  │
              │  │ new-api  :3001 │  │  计费 / 限流 / 协议转换
              │  │  host 网络     │  │
              │  └───────┬────────┘  │
              │          │           │
              │  ┌───────▼────────┐  │
              │  │ SMG 网关       │  │  sessionkey-v2 路由
              │  │ :30010 数据面  │  │  :29010 metrics
              │  └──┬──┬──┬──┬───┘  │
              │     │  │  │  │      │
              │  ┌──▼┐┌▼──┐┌▼──┐┌▼┐│
              │  │:58││:58││:58││:5│  SGLang v0.5.19
              │  │ 00││ 01││ 02││8│  AWQ-W4A16 + DFLASH
              │  └─┬─┘└─┬─┘└─┬─┘└┬┘  262144 ctx / fp8 KV
              │   GPU3 GPU2 GPU1 GPU0
              │   170HX 170HX 170HX 170HX
              │                      │
              │  ┌────────────────┐  │
              │  │ 监控栈          │  │
              │  │ Prometheus :9090│ │
              │  │ Grafana    :3000│ │
              │  │ exporters  :19011/19012 │
              │  │ feishu-watch     │ │
              │  └────────────────┘  │
              └──────────────────────┘
```

请求全链路：`client → new-api:3001 → SMG:30010 → SGLang:5800-5803`

---

## 二、组件版本表

| 组件 | 版本/Tag | 镜像 | 端口 |
|---|---|---|---|
| SGLang | v0.5.19 + 补丁 0001-0006 | `sglang:dflash2-fullstack`（760 现役：`sglang:dflash2-ttl-tier4-tclook-0917`） | 5800-5803 |
| 模型 | Qwen3.8-27B AWQ-W4A16 | `/mnt/data/models/eff-awq-w4a16/NVFP4/AWQ-W4A16` | — |
| DFLASH draft | Qwen3.8-27B-DFlash2, block_size=8 | `/mnt/data/models/Qwen3.8-27B-DFlash2` | — |
| SMG 网关 | sessionkey-v2 | `sglang-gateway:sessionkey-v2` | 30010 / 29010 |
| new-api | fixtoolidx-0831-full (rc25 世代) | `new-api:fixtoolidx-0831-full` | 3001 |
| Prometheus | latest | `prom/prometheus:latest` | 9090 |
| Grafana | 13.2.1 | `grafana/grafana:13.2.1` | 3000 |
| node-exporter | latest | `prom/node-exporter:latest` | 9100 |
| 760-exporters | python:3.12-slim | `python:3.12-slim` | 19011 / 19012 |

---

## 三、仓库目录地图

```
.
├── README.md              # 本文件：是什么 + 拓扑 + 版本 + 性能基线
├── DEPLOY.md              # 怎么构建与启动（唯一出处）
├── AGENTS.md              # AI 可执行命令序列 + 失败分支
├── PATCHES.md             # 所有改动出处（唯一出处）
├── TUNING.md              # 所有"为什么这组数"（唯一出处）
├── OPERATIONS.md          # Day-2 运维手册
├── BASELINE.md            # 全组件基线锁表（镜像/源树/wheel sha256）
├── .env.example           # 环境变量模板（无真值）
├── .gitignore
│
├── scripts/               # 有序构建/部署脚本
│   ├── 00-preflight.sh    # 前置检查（工具链/网络/GPU/磁盘/环境）
│   ├── 01-build-sglang.sh
│   ├── 02-build-gateway.sh
│   ├── 03-build-newapi.sh
│   ├── 04-build-monitoring.sh
│   ├── 05-start-sglang.sh
│   ├── 06-start-gateway.sh
│   ├── 07-start-newapi.sh
│   ├── 08-start-monitoring.sh
│   └── verify/            # 端到端验证脚本
│       ├── v1-sglang.sh
│       ├── v2-gateway.sh
│       ├── v3-newapi.sh
│       ├── v4-cc-warm.sh
│       └── v5-monitoring.sh
│
├── sglang/
│   ├── Dockerfile.base    # 基线 + 0001-0005 补丁 + 硬门
│   ├── Dockerfile.prod    # base + 0006 tc-lookahead
│   ├── launch-awq.sh      # 生产启动脚本（4 卡）
│   ├── launch-int8.sh     # INT8 回滚版
│   ├── patches/           # 0001-0005 .patch + 0006 整文件 + generators/
│   ├── overlay/           # bind-mount 3 件（serving_chat, http_server, chat_template）
│   ├── cc-warm/           # CC 前缀预热 JSON + test 脚本
│
├── gateway/               # SMG 源（sessionkey-v2 现行，已剔除上游 test/bench/examples/golang 绑定）
│   ├── src/  bindings/python/  Cargo.toml  Makefile  rust-toolchain.toml ...
│   ├── run-router.sh      # 权威启停脚本
│   └── .gitignore         # 排除 target/、.bak-*/
│
├── new-api/
│   ├── Dockerfile         # 全量构建（web + go）
│   ├── Dockerfile.go-only # 快速路径（已有 web/dist）
│   ├── overlay/           # 7 文件定制（敏感词豁免/对话留痕）
│   ├── run-newapi.sh
│   └── newapi-channels.sh
│
├── monitoring/
│   ├── prometheus.yml  rules.yml
│   ├── exporters.py  feishu-watch.py
│   ├── launch-observability.sh
│   ├── grafana/
│   │   ├── dashboards/sglang-760.json
│   │   └── provisioning/ (datasources + dashboards)
│   └── env/ (feishu.env.example, grafana.env.example)
│
└── models/
    ├── dl-effthink.sh     # 权重下载脚本
    └── SHA256SUMS
```

---

## 四、快速开始

1. 复制 `.env.example` → `.env`，填入真值
2. 按序执行 `scripts/00` → `04`（构建）
3. 按序执行 `scripts/05` → `08`（启动）
4. 逐层验证 `scripts/verify/v1` → `v5`

完整命令见 `DEPLOY.md`，AI 可执行版见 `AGENTS.md`。

---

## 五、性能基线（当前生产实测）

> 口径 = 现役配置：AWQ-W4A16 + DFLASH2（block_size 8）+ chunk 8192 + no-prefill-graph + tier4 前缀常驻。
> 出处：09-15 单卡实测（launch-awq.sh 同参）+ 09-12 四卡切换 / 09-13 CC 前缀预热实测，全部活体数据。

### 5.1 单请求解码吞吐（c1，单卡）

| 输入 tok | 输出 tok | 解码 tok/s | TTFT |
|---:|---:|---:|---:|
| 511 | 259 | 218.6 | 0.37 s |
| 1 022 | 256 | 299.5 | 0.68 s |
| 2 044 | 256 | 248.8 | 1.27 s |
| 4 088 | 256 | 271.3 | 2.40 s |
| 8 176 | 256 | 223.7 | 4.88 s |
| 16 352 | 258 | 243.3 | 10.0 s |
| 32 704 | 257 | 190.2 | 21.4 s |
| 65 408 | 258 | 183.8 | 49.2 s |

- 长上下文（65 408）vs 短上下文（511）吞吐衰减仅 **1.2×**
- 注：`max_tokens=128` 只限 content，输出 tok 为服务端实产（content + reasoning）

### 5.2 CC 新会话前缀缓存

- 常驻前缀 20 144 tok（纯 system + tools），新会话命中率 **99.8–99.9%**
- 首 turn TTFT：冷启动 **15 s** → 热 **0.42 s**（~37×）

### 5.3 KV 池容量（mem-fraction 0.9）

- 主 KV 池（fp8_e4m3）**659 346 tokens/卡**，全 fleet **2 637 384**
- 较 INT8 基线（416 122/卡）**+58.4%**

### 5.4 四卡 fleet 并发（INT8 代 · 冷 prefill）

> ⚠️ 冷 prefill 口径（09-11 压测，前缀缓存未命中）。热 prefill（CC 前缀缓存命中后）TTFT 与吞吐均显著更快。
> 模型：Qwen3.8-27B INT8 W8A16 · DFLASH2 · chunk 4096 · hicache-ratio 1.5

| 并发 | fleet tok/s | 单请求 tok/s p50 | TTFT p50 | TTFT p99 |
|---:|---:|---:|---:|---:|
| c1 | 85 | 87.7 | 0.17 s | 0.17 s |
| c4 | 275 | 92.9 | 0.26 s | 0.26 s |
| c8 | 392 | 85.6 | 0.41 s | 0.60 s |
| c16 | 708 | 65.7 | 0.58 s | 0.64 s |
| c24 | 978 | 57.8 | 0.85 s | 1.12 s |
| c32 | 1 074 | 65.3 | 0.97 s | 8.93 s |
| c48 | 1 165 | 56.1 | 1.42 s | 10.29 s |
| c64 | **1 394** | 59.0 | 8.11 s | 17.17 s |

- 拐点 **c32**（= 4 × max-running-requests 8）；c32 以下 TTFT < 1 s
- 四卡 GPU 利用率恒 94–96%，0 错 / 0 OOM
