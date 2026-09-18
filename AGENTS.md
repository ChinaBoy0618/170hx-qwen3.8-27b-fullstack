# AGENTS.md — AI 可执行部署序列

> 供 AI Agent 按序执行。每步有验证命令和失败分支。
> 人类操作参考 `DEPLOY.md`；本文件侧重**可执行命令 + 失败处置**。

## 全局前置

```bash
# 0. 进入仓库根目录
cd /path/to/170HX-Qwen3.8-27B-fullstack

# 1. 加载环境变量
set -a; source .env; set +a
```

| 失败 | 处置 |
|---|---|
| `.env` 不存在 | 从 `.env.example` 复制并填入真值 |
| `SGLANG_API_KEY` 为空 | 中止，提示用户设置 |

---

## 构建阶段

### B0 — 前置检查

```bash
bash scripts/00-preflight.sh
```

| 失败 | 处置 |
|---|---|
| docker daemon 未运行 | `systemctl start docker` 或联系用户 |
| GPU 数量 < 4 | 中止，硬件不满足 |
| 磁盘 < 100 GB | 中止，清理或扩容 |
| sglang 基础镜像拉取失败 | 检查网络/镜像仓库可达性，或离线加载 |
| SGLANG_API_KEY 未设 | 中止，提示设置 |

### B1 — SGLang 镜像

```bash
bash scripts/01-build-sglang.sh
```

| 失败 | 处置 |
|---|---|
| G1 基线 md5 不匹配 | 基础镜像被篡改或版本漂移，重新 pull 正确 digest |
| G2 补丁应用 fuzz/offset | 基础镜像版本与预期 0.5.19 不一致 |
| G3 补丁后 md5 不匹配 | 补丁文件被改动，重新生成（见 `PATCHES.md`） |
| G4 import 失败 | 依赖缺失，检查镜像内 pip 包版本 |
| docker build 超时 | 检查网络，或离线导入基础镜像 |

### B2 — SMG 网关镜像

```bash
bash scripts/02-build-gateway.sh
```

| 失败 | 处置 |
|---|---|
| cargo/rustup 未装 | `curl https://sh.rustup.rs -sSf \| sh` |
| maturin 未装 | `pip install maturin` |
| 编译失败 | 检查 `rust-toolchain.toml` 指定版本是否已安装 |
| wheel 未生成 | 检查 `bindings/python/` 目录完整性 |

### B3 — new-api 镜像

```bash
bash scripts/03-build-newapi.sh
```

| 失败 | 处置 |
|---|---|
| go mod download 失败 | 检查 GOPROXY 可达性 |
| bun 构建失败 | 检查 `web/` 目录完整性 |
| overlay 文件缺失 | 确认 `new-api/overlay/` 7 文件齐全 |

### B4 — 监控镜像

```bash
bash scripts/04-build-monitoring.sh
```

| 失败 | 处置 |
|---|---|
| 镜像拉取失败 | 离线导入或使用内网镜像源 |

---

## 启动阶段

### S1 — SGLang 四卡

```bash
bash scripts/05-start-sglang.sh
```

| 失败 | 处置 |
|---|---|
| 容器状态 ≠ running | `docker logs <name>` 查看错误；检查端口冲突 |
| health 超时 (900s) | 模型加载慢或 OOM；`docker logs --tail 50` 诊断 |
| 容器 EXITED | 显存不足/模型路径错误；`docker inspect` 查看 exit code |
| CC 前缀双暖失败 | 非致命，不影响推理；检查 `warm-cc-prefix.json` 存在 |

### S2 — SMG 网关

```bash
bash scripts/06-start-gateway.sh
```

| 失败 | 处置 |
|---|---|
| 无 worker 发现 | 确认 5800-5803 容器均 running 且 `/health` 200 |
| 注册超时 | SGLang 仍在加载模型，等待后重跑 `bash run-router.sh register` |
| 端口冲突 | `ss -ltn \| grep 30010` 找占用进程 |

### S3 — new-api

```bash
bash scripts/07-start-newapi.sh
```

| 失败 | 处置 |
|---|---|
| 端口冲突 | 旧容器未清理；`docker rm -f new-api` |
| /api/status 非 200 | `docker logs new-api --tail 30` |

### S4 — 监控栈

```bash
bash scripts/08-start-monitoring.sh
```

| 失败 | 处置 |
|---|---|
| Prometheus 启动失败 | 检查 `prometheus.yml` 语法；`docker logs 760-prometheus` |
| Grafana 启动失败 | 检查 `grafana.env` 权限 (chmod 400) |
| exporter 不可达 | 检查 `exporters.py` 依赖；`docker logs 760-exporters` |

---

## 验证阶段（逐层）

```bash
bash scripts/verify/v1-sglang.sh      # 4 卡推理层
bash scripts/verify/v2-gateway.sh     # 网关路由
bash scripts/verify/v3-newapi.sh      # new-api
bash scripts/verify/v4-cc-warm.sh     # 前缀缓存
bash scripts/verify/v5-monitoring.sh  # 监控栈
```

每个脚本末尾输出 `PASS` 或 `FAIL`。全部 PASS 视为部署完成。

### 验证失败处置

| 脚本 | 常见失败 | 处置 |
|---|---|---|
| v1 | health 非 200 | 回到 S1，检查容器日志 |
| v1 | DFLASH 未生效 | 检查 `--speculative-algorithm` 参数；检查 draft 模型路径 |
| v2 | 会话不粘滞 | 检查 `session-routing.json` 持久化目录；检查网关版本 |
| v2 | 负载均衡不均 | 检查 `--policy manual --assignment-mode min_load` 参数 |
| v3 | /v1/messages 404 | 检查 new-api channel 配置（base_url 指向 :30010） |
| v4 | 命中率 < 99% | 检查双暖是否执行（两次 curl 均成功）；检查 `pin_prefix` 响应 |
| v5 | targets 不 up | 检查 Prometheus scrape 配置；检查各 exporter 端口可达性 |

---

## 完整执行序列（一行版）

```bash
set -a; source .env; set +a
bash scripts/00-preflight.sh && \
bash scripts/01-build-sglang.sh && \
bash scripts/02-build-gateway.sh && \
bash scripts/03-build-newapi.sh && \
bash scripts/04-build-monitoring.sh && \
bash scripts/05-start-sglang.sh && \
bash scripts/06-start-gateway.sh && \
bash scripts/07-start-newapi.sh && \
bash scripts/08-start-monitoring.sh && \
bash scripts/verify/v1-sglang.sh && \
bash scripts/verify/v2-gateway.sh && \
bash scripts/verify/v3-newapi.sh && \
bash scripts/verify/v4-cc-warm.sh && \
bash scripts/verify/v5-monitoring.sh
```
