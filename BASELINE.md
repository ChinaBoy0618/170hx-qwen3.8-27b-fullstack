# BASELINE.md — 全组件基线锁表

> 本文件锁定所有组件的镜像 tag + digest、源树 sha256、关键文件校验。
> 构建/部署时用于校验一致性。任何变更必须更新此表。

---

## 一、镜像基线

| 组件 | 镜像 tag | 基线 digest (sha256) | 760 实测大小 | 构建来源 |
|---|---|---|---|---|
| SGLang 基线 | `lmsysorg/sglang:v0.5.19` | `e6238090791a938ab86dd21a9a6394192dad15237e815df557cf83524d54b813` | — | Docker Hub |
| SGLang 760 现役 | `sglang:dflash2-ttl-tier4-v6` | `70a49a84a26f6cbb8862f31e1ff610a10e13dbe3b098f3d15e847e67686af300` | 36.4 GB | `Dockerfile.base` + `Dockerfile.prod`（含 0007 + 0008 v6 缩放驱逐器） |
| SGLang 回滚锚 | `sglang:dflash2-ttl-tier4-v5` | `f820ae0c69f63b7fdb0905dccc609a1b8a4ed076e91af7014e6562a3a2449a17` | 33.9 GB | 0007 v5 驱逐器（256 固定上限） |
| SGLang 回滚锚 | `sglang:dflash2-ttl-tier4-tclook-0917` | `fefc9a3d6da63eb2cf745e5513f7b5b8382881ec90f755786656fd6f204d8077` | 36.4 GB | `Dockerfile.base` + `Dockerfile.prod`（v5 前版，O(1) 头弹驱逐器） |
| SMG 网关 | `sglang-gateway:sessionkey-v2` | `fefc9a3d6da63eb2cf745e5513f7b5b8382881ec90f755786656fd6f204d8077`* | 44.1 GB | `gateway/` 整树 + cargo/maturin |
| new-api | `new-api:fixtoolidx-0831-full` | `aab1b94f18fa7110b3e7ba7165354479891e4cedf10821cdfcdc62bb51a1fd74` | 213 MB | `new-api/Dockerfile` |
| Prometheus | `prom/prometheus:latest` | `31c1e0aacb3a1914563c4e9b1e8d0a55095bf433aa43c1b0fe695959742845bd` | — | Docker Hub |
| Grafana | `grafana/grafana:13.2.1` | `8400f365c39767b0d0df30e3aeb0796f873c3acf89b28089745bfafd88d83c7c` | — | Docker Hub |
| node-exporter | `prom/node-exporter:latest` | `9bbbca8f5cb8e9bd1b835e8ec086b6df6d9a458d2d10ef1c97ea4a9a3ae7e54b` | — | Docker Hub |
| Python (exporters) | `python:3.12-slim` | `25c5b8011a3425a140bf5fa73be0feabd3c0d5b323eecb19dc02437a368ae075` | — | Docker Hub |

> * 760 上 SGLang 与 SMG 网关的 `.Id` 相同可能因共享 CUDA base 层；重新构建后以实际 `docker image inspect` 输出回填。

---

## 二、源树 / 关键文件 sha256

### 2.1 SGLang 补丁文件

| 文件 | sha256 |
|---|---|
| `sglang/patches/0001-ttl-rebase-0519.patch` | `279e96783601401bd56158266daff438166f0518fe707eed0789786b154dcab4` |
| `sglang/patches/0002-ttl-tier2-eviction.patch` | `c9fcd5fd258593ad485f28ca95b42930b721890aa27a17dc0b6ad1d3dd0abb7f` |
| `sglang/patches/0003-ttl-tier3-unified.patch` | `982ba62afe26d985a6388a012c7d4a04b36654a7bc0fc69de0bcbcb29a412402` |
| `sglang/patches/0004-ttl-tier3b-stamp.patch` | `96537ac4288e3dbb9bf3ec9ce13fd7c72395dc71766d309d31183085ffcb277b` |
| `sglang/patches/0005-ttl-tier4-pin.patch` | `661e590970e47c3916a6506d6215c1384d163d3c12c7794867b093352332d1ae` |
| `sglang/patches/0006-tc-lookahead/reasoning_parser.py` | `4166fb8d882e1c0e5d9baff82d462972434cb9db04ffed61d957e032e6b3814f` |
| `sglang/patches/0007-v5-heat-evictor/lru_file_evictor.py` | `b7aebacecbc57f2cc628c7c040ca813b4a1d6c499e5fb1548e6eaf76c2053cb7` |
| `sglang/patches/0007-v5-heat-evictor/scheduler.py` | `e330de1a8d455bf5a9c8faf3c0a485d492773845ee4f840be8b918355fd162c4` |
| `sglang/patches/0007-v5-heat-evictor/unified_radix_cache.py` | `a0cf59cbbbb2744b6bc43ea83fc1ef4388c1524b959b7cd6c7ce3d8fb6e43f06` |
| `sglang/patches/0007-v5-heat-evictor/unified_tree_core.py` | `f325b80dc1470e017afe5d18658f345c4a74b89ccda637465f40c91d66c8d74e` |
| `sglang/patches/0008-v6-scaled-evictor/lru_file_evictor.py` | `c7e2ed308c8e9d6afc6f99916b22b0e84ee6a047aeb739b484f8dc1fa997f138` |

### 2.2 SGLang overlay（bind-mount 件）

| 文件 | sha256 |
|---|---|
| `sglang/overlay/serving_chat.py` | `1f879f8083005c8e90795289b372e6132e18bb22ccf9a79e67166ee285cc3449` |
| `sglang/overlay/http_server.py` | `2cc6f3042ddc4dad818a968e4607eab8d05b66858c3666c4fe46761b8b51e9cc` |
| `sglang/overlay/chat_template-fix.jinja` | `373628a234697404f78f661e59617b3f2bcdefdd4a9f6caa7df94c207203c2b3` |

### 2.3 启动 / 运维脚本

| 文件 | sha256 |
|---|---|
| `sglang/launch-awq.sh` | `2d9117878870f13d8d76ce01e7e151f4b8a27fdc0184a6dc8a38b4412f36c0d8` |
| `sglang/launch-int8.sh` | `af674c9fdd18c5e74ac114468a53263109ed17da03cd787335a6387f8815cb01` |
| `gateway/run-router.sh` | `f5d4d577c66fde2f340121872253e715ab3fc4e8f37d8f7c771f2540252e83ab` |
| `new-api/run-newapi.sh` | `5cb1a00776e187ccf368b88aff4d0b6d7921a0bc602286329df1b5d97a3db306` |
| `scripts/10-rolling-rollout.sh` | `7cabba3d3376dd6135454fa72887802595e8b34ec01e37df83d639df1d294fb6` |
| `scripts/canary-watchdog.sh` | `f077cef5a69e401433b79475f308889c37075374893d999d8d58ca29207d5a58` |
| `scripts/stress-16c.py` | `51b0a87e4fdf2acd6bae39689af32126c182abf4bab1d4297ef022885e830411` |
| `scripts/monitor-stress.sh` | `d117c7eb7e7afc52227a5f20f3b1b812bdc2bec30f2c45fa58722dcfe5bf9d91` |

### 2.4 SMG 网关

| 文件 | 说明 |
|---|---|
| `gateway/sessionkey-v2-src.diff` | sessionkey-v2 增量 diff（711 行） |
| `gateway/Cargo.lock` | Rust 依赖锁定 |
| `gateway/rust-toolchain.toml` | Rust 工具链版本锁定 |

### 2.5 new-api overlay（7 文件）

| 文件 | 说明 |
|---|---|
| `new-api/overlay/setting/sensitive.go` | 敏感词过滤 + 用户豁免 |
| `new-api/overlay/controller/relay.go` | 路由层敏感词检查 |
| `new-api/overlay/model/option.go` | 豁免用户 ID 配置 |
| `new-api/overlay/relay/common/relay_info.go` | relay 信息扩展 |
| `new-api/overlay/relay/channel/claude/relay-claude.go` | Claude 通道适配 |
| `new-api/overlay/relay/channel/openai/relay-openai.go` | OpenAI 通道适配 |
| `new-api/overlay/service/log_info_generate.go` | 对话留痕 |

---

## 三、构建硬门汇总

| 门 | 位置 | 检查内容 |
|---|---|---|
| G1 (base) | `Dockerfile.base` | 11 文件 pristine 0.5.19 md5 全等 |
| G2 (base) | `Dockerfile.base` | 0001-0005 干净应用（无 fuzz/offset） |
| G3 (base) | `Dockerfile.base` | 补丁后 11 文件 md5 == 760 生产树 |
| G4 (base) | `Dockerfile.base` | import 冒烟（DFlash2 / CandidateSelector / TTLWatermarkStrategy / flashinfer≥0.6.18） |
| G1 (prod) | `Dockerfile.prod` | reasoning_parser.py md5 == 760 活体 (`d2d352a4ceb1bafb4feecd3d905f50dc`) |
| G2 (prod) | `Dockerfile.prod` | Qwen3Detector `_tc_lookahead` 行为验证 |
| G5 (prod) | `Dockerfile.prod` | 0007 四文件 md5 == 760 v5 现役树（lru_file_evictor / scheduler / unified_radix_cache / unified_tree_core） |
| G6 (prod) | `Dockerfile.prod` | v5 驱逐器行为冒烟（`islice` 64 窗口 + `evictions < cap` 有界上限） |
| G7 (prod) | `Dockerfile.prod` | 0008 `lru_file_evictor.py` md5 == 760 v6 构建树（`013751d9…`） |
| G8 (prod) | `Dockerfile.prod` | v6 驱逐器行为冒烟（`_eviction_cap_for` 存在 + `islice` 有界扫描 + `16384` 硬顶 + 参数化 cap） |

---

## 四、模型权重

| 模型 | 760 路径 | 来源 | 校验文件 |
|---|---|---|---|
| Qwen3.8-27B AWQ-W4A16 | `/mnt/data/models/eff-awq-w4a16/NVFP4/AWQ-W4A16/` | ModelScope `Merkyor/Qwen3.8-27B-EfficientThink-K3-Opus5-Grok4.6-GPT5.6Sol-SFT-SimPO-DFlash2` | `models/SHA256SUMS` |
| Qwen3.8-27B DFlash2 (draft) | `/mnt/data/models/Qwen3.8-27B-DFlash2/` | 同上仓库 | — |

- **quantization_config**：compressed-tensors int4/group128 (W4A16)
- **vision tower**：BF16 未量化（`ignore: re:.*visual.*`）
- **下载脚本**：`models/dl-effthink.sh`
