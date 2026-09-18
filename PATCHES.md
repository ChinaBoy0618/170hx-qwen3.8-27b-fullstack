# PATCHES.md — 改动出处唯一索引

> 本文件是 SGLang 补丁链、overlay、SMG 4 旧补丁、new-api 7 文件的**唯一**改动来源说明。
> 构建时由 `Dockerfile` 自动校验；变更须同步更新本文件与 `BASELINE.md`。

---

## 一、SGLang 补丁链（0001-0006）

### 应用方式
- **0001-0005**：在 `Dockerfile.base` 中 `patch -p1` 按序应用，前缀 `a/` `b/`
- **0006**：整文件替换 `reasoning_parser.py`（非 diff），在 `Dockerfile.prod` 中 COPY

### 补丁详情

| # | 文件名 | 改动内容 | 生成器 |
|---|---|---|---|
| 0001 | `0001-ttl-rebase-0519.patch` | 将 0.5.18 世代 TTL 水位驱逐机制 rebase 到 v0.5.19 源树；涉及 `managers/scheduler.py`、`mem_cache/evict_policy.py`、`mem_cache/unified_cache/unified_tree_core.py`、`server_args.py` 等 11 文件 | `generators/_ttl_patch_0519.py` |
| 0002 | `0002-ttl-tier2-eviction.patch` | 阈值 0.85→0.75，使 tier2 在更低水位即开始驱逐 | `generators/_ttl_tier2_0912.py` |
| 0003 | `0003-ttl-tier3-unified.patch` | tier3 统一到 `kv_cache` / `token_to_kv_pool_allocator.size_full` 双源，消除 `UnifiedRadixCache` 兼容问题 | `generators/_ttl_tier3_0914.py` |
| 0004 | `0004-ttl-tier3b-stamp.patch` | 为 tier3b 注入 TTL 时间戳回调（`_ttl_stamper`），支持分级 TTL 策略 | `generators/_ttl_tier3b_0914.py` |
| 0005 | `0005-ttl-tier4-pin.patch` | 新增 `POST /admin/pin_prefix` 端点，将 CC 前缀钉住不驱逐（evictable 20191→63） | `generators/_ttl_tier4_pin_0914.py` |
| 0006 | `0006-tc-lookahead/reasoning_parser.py` | 整文件替换：Qwen3Detector 开启 `_tc_lookahead=True` + `tc_block_prefix="<function="`，修复 thinking 内工具标签泄漏（09-17） | `generators/patch_tc_lookahead.py`（7 锚点，幂等校验，失配 exit 1） |

### 硬门校验（Dockerfile 内）
- **G1**：11 个基线文件 pristine 0.5.19 md5 全等（防止镜像被篡改）
- **G2**：0001-0005 以 `patch -p1` 干净应用（无 fuzz/offset）
- **G3**：补丁后 11 文件 md5 与 760 生产树一致
- **G4**：import 冒烟（`DFlash2DraftModel` / `CandidateSelector` / `TTLWatermarkStrategy` / `flashinfer>=0.6.18`）

### 再生成方法
```bash
# 从 pristine 0.5.19 源树重新生成全部补丁
cd sglang/patches/generators
python3 _ttl_patch_0519.py <pristine-tree>
python3 _ttl_tier2_0912.py  <pristine-tree>
python3 _ttl_tier3_0914.py  <pristine-tree>
python3 _ttl_tier3b_0914.py <pristine-tree>
python3 _ttl_tier4_pin_0914.py <pristine-tree>
python3 patch_tc_lookahead.py <pristine-tree>
```

---

## 二、SGLang overlay（bind-mount 3 件）

生产容器通过 `docker run -v` 挂载，**不在镜像内**：

| 文件 | 用途 | 关键改动 |
|---|---|---|
| `overlay/serving_chat.py` | parallel-toolfix（09-11 hardened）+ keepalive | 多工具并行解析、流式 SSE keepalive 30s |
| `overlay/http_server.py` | tkw-auth（多 tokenizer-worker + api-key）+ pin 端点 | `--tokenizer-worker-num > 1` 时鉴权不崩 |
| `overlay/chat_template-fix.jinja` | 修复 `tool_reference` 字段缺失 | CC 客户端不再因字段缺失解析失败 |

**幂等补打守卫**：`launch-awq.sh` 第 71-88 行在 `docker run` 前自动检查 `serving_chat.py` 和 `http_server.py` 是否含补丁标记；缺失则从 `overlay/patches/` 补打，失配则中止启动。

**canary opt-in**（不在生产挂载）：
- `overlay/optional/dflash.py`、`dflash_utils.py`、`fused_kv_materialize.py`
- 仅 `SGLANG_DFLASH_PATCH=1` 时挂载（WNA16 fused-KV 实验）

---

## 三、SMG 网关

### 4 旧补丁（烘在 08-21 快照内，无独立 .patch 文件）

| 补丁 | 落点文件 | 效果 |
|---|---|---|
| 08-21 main 快照 | 整树 | 基线版本 |
| #33138 tie-break | `src/policies/` | 同分 worker 用最小 load 打破平局 |
| B+ 剥 null | `src/routers/http/router.rs` | 移除 `strip_nulls`（SGLang 0.5.19 已自带） |
| anthropic raw-passthrough | `src/middleware.rs` + `src/server.rs` + `src/routers/router_manager.rs` | 原生 `/v1/messages` 路由 + x-api-key 鉴权 |

### sessionkey-v2（09-17 上线）

**改动**：`--policy manual --assignment-mode min_load` + 路由表持久化

**路由 key 优先级**：
1. `x-smg-routing-key`（显式指定）
2. `x-claude-code-session-id`（CC 会话粘滞）
3. `c:xxh3(前 8192 字符)`（内容哈希缓存亲和）
4. `min_load`（无 key 时最小 load）

**持久化**：`session-routing.json`，60s 原子快照，4h TTL 自动清理

**diff**：`gateway/sessionkey-v2-src.diff`（711 行，8 文件增量）

**回滚锚**：`run-router.sh.bak-cacheaware-0917`（cache_aware 0.2/4/1.1 配置）

---

## 四、new-api 7 文件 overlay

**上游**：QuantumNous/new-api rc25 世代（0831），非 git 仓库

| 文件 | 改动 |
|---|---|
| `overlay/setting/sensitive.go` | 全局敏感词过滤 + 用户 ID 豁免（`SensitiveWordExemptUserIDs`） |
| `overlay/controller/relay.go` | 路由层：敏感词检查插入点 + 豁免逻辑 |
| `overlay/model/option.go` | 豁免用户 ID 配置项 |
| `overlay/relay/common/relay_info.go` | relay 信息结构体扩展 |
| `overlay/relay/channel/claude/relay-claude.go` | Claude 通道适配（header 透传） |
| `overlay/relay/channel/openai/relay-openai.go` | OpenAI 通道适配 |
| `overlay/service/log_info_generate.go` | 对话留痕：prompt/response 写 `logs.other` |

**基线锚点**：`new-api/BASELINE.md`（go.mod + 未改锚点文件 md5）
