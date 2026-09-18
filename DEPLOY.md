# DEPLOY.md — 构建与启动唯一出处

> 本文是**唯一**的"怎么构建与启动"参考。
> 环境变量模板见 `.env.example`，AI 可执行命令序列见 `AGENTS.md`，
> 补丁出处见 `PATCHES.md`，参数调优依据见 `TUNING.md`。

---

## 一、环境准备

### 1.1 硬件要求

| 项 | 最低 |
|---|---|
| GPU | 4× NVIDIA 170HX (sm_80, 64 GB VRAM/卡) |
| RAM | 256 GB |
| NVMe | ≥ 100 GB 可用 (模型 + L3 KV 缓存) |
| 磁盘 | ≥ 300 GB 总量 (Docker 镜像 + 模型) |

### 1.2 软件要求

| 工具 | 用途 | 最低版本 |
|---|---|---|
| Docker (daemon) | 容器运行时 | 24.x+ |
| nvidia-container-toolkit | GPU 容器化 | 1.14+ |
| docker compose v2 | 编排（可选） | 2.20+ |
| cargo + rustup | 网关构建 (仅重建时) | stable |
| Go 1.26.1 | new-api 构建 (仅重建时) | 1.26.1 |
| Node.js | new-api channel 脚本 (sqlite) | 22+ |
| Python 3 | SGLang 补丁校验 | 3.10+ |
| curl, jq | 验证脚本 | — |

### 1.3 环境变量

复制 `.env.example` 为 `.env` 并填入真值：

```bash
cp .env.example .env
```

关键变量（完整清单见 `.env.example`）：

| 变量 | 示例值 | 说明 |
|---|---|---|
| `SGLANG_API_KEY` | `sk-xxxx` | SGLang `--api-key` |
| `SGLANG_MODEL_PATH` | `/mnt/data/models/eff-awq-w4a16/NVFP4/AWQ-W4A16` | 主模型路径 |
| `SGLANG_DRAFT_PATH` | `/mnt/data/models/Qwen3.8-27B-DFlash2` | DFLASH draft 路径 |
| `SGLANG_CTX_LEN` | `262144` | 上下文长度 |
| `SGLANG_IMG` | `sglang:dflash2-fullstack` | SGLang 镜像 tag |
| `GATEWAY_PORT` | `30010` | SMG 数据面端口 |
| `NEWAPI_PORT` | `3001` | new-api 端口 |
| `NEWAPI_KEY` | `nk-xxxx` | new-api 调用方 key |
| `FEISHU_WEBHOOK` | `https://open.feishu.cn/...` | 飞书告警 webhook |

---

## 二、构建阶段（顺序执行，每步完成后再进行下一步）

### 2.0 前置检查

```bash
source .env
bash scripts/00-preflight.sh
```

**通过标准**：全部 `[OK]`，`ALL PASS — ready to build`。

### 2.1 SGLang 镜像

```bash
bash scripts/01-build-sglang.sh
```

**产物**：
- `sglang:dflash2-fullstack-base`（v0.5.19 + 0001-0005 补丁）
- `sglang:dflash2-fullstack`（+ 0006 tc-lookahead）
- 同步 tag：`sglang:dflash2-ttl-tier4-tclook-0917`

**硬门（Dockerfile 内自动执行）**：
- G1: 11 个基线文件 md5 与 v0.5.19 pristine 一致
- G2: 补丁 0001-0005 干净应用（无 fuzz/offset）
- G3: 补丁后 11 文件 md5 与 760 生产树一致
- G4: import 冒烟（DFlash2 / CandidateSelector / TTLWatermarkStrategy / flashinfer≥0.6.18）

### 2.2 SMG 网关镜像

```bash
bash scripts/02-build-gateway.sh
```

**产物**：`sglang-gateway:sessionkey-v2`

**说明**：网关为 Rust 整树构建，需 cargo + maturin。构建耗时约 10-20 分钟。
若已有预构建 wheel，可跳过此步。

### 2.3 new-api 镜像

```bash
bash scripts/03-build-newapi.sh
```

**产物**：`new-api:fixtoolidx-0831-full`

**说明**：全量构建含 web (bun) + go (golang:1.26.1-alpine)。快速路径可用 `Dockerfile.go-only`。

### 2.4 监控镜像

```bash
bash scripts/04-build-monitoring.sh
```

**说明**：拉取标准镜像（prometheus / grafana / node-exporter / python），无需编译。

---

## 三、启动阶段（顺序执行，依赖关系：sglang → gateway → newapi / monitoring）

### 3.1 SGLang 四卡

```bash
bash scripts/05-start-sglang.sh
```

**行为**：依次启动 4 个 SGLang 容器（GPU 0-3 → 端口 5800-5803），每卡等待 health 200 后触发 CC 前缀双暖 + pin。

**成功标志**：4 个容器均输出 `HEALTHY`，`/v1/models` 返回 `qwen3.8`。

### 3.2 SMG 网关

```bash
bash scripts/06-start-gateway.sh
```

**行为**：自动发现 5800-5803 端口上的 SGLang 容器，注册到 SMG 控制面，启动 :30010 数据面 + :29010 metrics。

**成功标志**：`/health` 返回 200，`/workers` 列出 4 个 worker。

### 3.3 new-api

```bash
bash scripts/07-start-newapi.sh
```

**成功标志**：`/api/status` 返回 200。

### 3.4 监控栈

```bash
bash scripts/08-start-monitoring.sh
```

**成功标志**：Prometheus targets 全 up，Grafana /api/health 返回 200。

---

## 四、逐层验证

| 序号 | 命令 | 验证目标 |
|---|---|---|
| v1 | `bash scripts/verify/v1-sglang.sh` | 4 卡 health + 最小 chat + nvidia-smi + DFLASH |
| v2 | `bash scripts/verify/v2-gateway.sh` | 网关 health + 会话粘滞 + min_load 均衡 |
| v3 | `bash scripts/verify/v3-newapi.sh` | new-api health + /v1/messages + 敏感词豁免 |
| v4 | `bash scripts/verify/v4-cc-warm.sh` | CC 前缀双暖 + 新会话命中 ≥99% |
| v5 | `bash scripts/verify/v5-monitoring.sh` | Prometheus targets + exporters + Grafana |

全部通过后方可视为部署完成。

---

## 五、启动顺序依赖图

```
00-preflight
    │
    ├── 01-build-sglang ──────────────────────┐
    ├── 02-build-gateway ─────────────────────┤
    ├── 03-build-newapi ──────────────────────┤  (可并行)
    └── 04-build-monitoring ──────────────────┘
    │
    ▼
05-start-sglang  ← 依赖 01
    │
    ▼
06-start-gateway ← 依赖 05 (需要 5800-5803 就绪)
    │
    ├── 07-start-newapi    ← 可并行
    └── 08-start-monitoring ← 可并行
    │
    ▼
v1 → v2 → v3 → v4 → v5  (逐层验证)
```

---

## 六、回滚

| 组件 | 回滚方法 |
|---|---|
| SGLang | `SGLANG_IMG=sglang:dflash2-ttl-tier4 bash scripts/05-start-sglang.sh`（去掉 0006 补丁） |
| SMG 网关 | 见 `run-router.sh.bak-cacheaware-0917`（已含在 gateway/ 目录） |
| new-api | 重建 `new-api:fixtoolidx-0831`（无 0831-exempt 版本） |
