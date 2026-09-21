# Release v1.0.0 — 2026-09-21

首个正式版本。锁定 760 四卡生产栈全部组件及其校验基线。

## 组件

| 层 | 镜像 / 脚本 | 版本标识 |
|---|---|---|
| SGLang 引擎 | `sglang:dflash2-ttl-tier4-v6` (`70a49a84a26f`) | 0.5.19 + 0001–0008 补丁 |
| SMG 网关 | `sglang-gateway:sessionkey-auto-register-0919b` (`b2c0a188938e`) | sessionkey-v2 + autoreg |
| new-api | `new-api:fixtoolidx-0831-full` | tool idx fix |
| 起服 | `launch-awq.sh` (sha256 `2d911787…`) | chunk=8192, no-prefill-graph, TKW=4 |
| 回滚脚本 | `launch-int8.sh` (sha256 `b5f2bf24…`) | INT8 回滚用 |

## 补丁清单

| # | 名称 | 要点 |
|---|---|---|
| 0001 | ttl-rebase-0519 | TTL 水线 rebase 到 0.5.19 |
| 0002 | ttl-tier2-eviction | 二级驱逐 |
| 0003 | ttl-tier3-unified | UnifiedRadixCache 打 TTL |
| 0004 | ttl-tier3b-stamp | 回载重打 TTL |
| 0005 | ttl-tier4-pin | 前缀 pin 常驻 |
| 0006 | tc-lookahead | thinking 块 tool 标签防泄漏 |
| 0007 | v5-heat-evictor | 64 窗口有界热度扫描 + 256 上限，修 O(n) 活锁 |
| 0008 | v6-scaled-evictor | 按请求大小缩放驱逐预算，修 mamba 78MB not caching |

## 验证

- v5 canary (5803, 2h, 16 并发): 1472/1472 PASS, fail=0
- v6 canary (5803, 2h, 16 并发): 1408/1391 (98%), fail 全为冷启动 120s 超时
- 四卡 rollout v6: 全绿 (~17 min, 09-21 14:40 完成)
- 生产稳态: si <50ms, gm 2ms, chat 200, SMG 4 worker healthy

## 已知残留（非阻塞）

- L3 近满时 16384 cap 偶发触顶 ~0.06/min → 少量 mamba 块 not caching（TTFT 微增，非稳定性）
  - 修复方案 C（预算修正）已设计，待 L3 文件数涨过 20M 或用户感知退化时实施
- 回滚锚: `sglang:dflash2-ttl-tier4-v5`

## 封存

- 760 现场封存清单: `/mnt/data/sglang-qwen38/SEAL-v1.0.0-20260921.txt`
- 镜像 tag: `sglang:fullstack-v1.0.0` / `sglang-gateway:fullstack-v1.0.0`
