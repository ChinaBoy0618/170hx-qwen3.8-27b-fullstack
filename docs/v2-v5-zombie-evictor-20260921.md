# v2→v5 僵尸卡事故与驱逐器活锁修复（2026-09-20/21）

> 状态：**已收口**。v5 为现役生产镜像（`sglang:dflash2-ttl-tier4-v5`，09-21 08:12 四卡全滚）。
> 本文是 v2 补丁家族（v2/v3/v4/v4fh）到 v5 修复的完整证据链：时间线、栈实锤、A/B 闭环、修复与验证、副作用（SMG autoreg 竞态）、特性废弃声明。

---

## 一、结论（TL;DR）

- **根因（栈实锤，非推断）**：v2 补丁把 L3 文件驱逐器 `_evict_one_lru_locked` 从 O(1) `popitem(last=False)` 改成 **O(n) 全索引 `min(committed, key=_score)` 扫描**；且 `_evict_while` 每次成功驱逐后重置 `attempts_left = len(self._lru)`。L3 近满（100G×0.9=90G 目标，实际 84–85%）+ write_back 降级压力下，每次 `reserve()`（L3 页写路径，backup 线程持锁）变成**多分钟 O(k·n) 扫描风暴** → backup 线程 100% CPU 钉死 → L3 写停摆 → D→H ack 永不完成 → 调度主循环 `check_hicache_events` 挂死 → **僵尸卡签名**（容器 Up / HTTP 活 / 引擎死 / `/get_model_info` 快）。
- **v5 修复**（仅 `lru_file_evictor.py`，三处 hunk）：64 窗口有界热度扫描 + 单次调用 256 驱逐硬上限 + 计数。镜像另烘 `ENV PYTHONFAULTHANDLER=1`（再僵死免重建直接抓栈）。
- **验证**：v5 2h canary 1472/1472 fail=0（对照 v2 死 ~4-5min、v4 死 ~2min）；四卡滚动 rollout 全绿；两卡 30min×16 并发压测各 400/400 fail=0，备份线程 10–11%（未钉死）→ **活锁不复现**。
- **特性废弃**：v2 引入的 **hot L3 backup**（调度主循环内 D→H 热节点备份）已废弃，生产保持 off（`getattr` no-op 门控）；三件承载文件（scheduler / unified_radix_cache / unified_tree_core）随 v5 镜像保留代码仅为字节一致，不再启用。**write_back 策略无罪**（老镜像带它活着），保留。

---

## 二、时间线（760 本地时区）

| 时间 | 事件 |
|---|---|
| 09-20 17:00 | v2 镜像 `sglang:dflash2-ttl-tier4-v2` 构建（tclook-0917 + 4 文件：hot L3 backup + 热度驱逐 + abort 写回 + write_back 策略） |
| 09-20 晚间 | 多卡陆续出现僵尸卡：容器 Up / HTTP 200 / 引擎死；`/get_model_info` 盲区（见 §六 鉴别签名） |
| 09-20 21:00–21:09 | 四卡全部用 tclook-0917 标准脚本重拉，恢复 |
| 09-20 21:4x | v2 canary 布置（5803 摘卡 → 重拉 → 日志落盘 → SMG 重注册 → 看门狗）；22:04 首查全绿 |
| 09-20 22:25 | v2 16 并发压测启动 → **22:29:58 看门狗判死**（si 挂死）；crash dump 57KB **无 Traceback = 无声僵死** |
| 09-20 22:45 | tclook-0917 重拉 5803 作 A/B 对照（L123 仍 write_back）→ 同负载下**存活**（b=187/192/195 全绿） |
| 09-20 23:17 | v3（关 hot backup，但带 restamp 参数 bug）→ **7s 硬崩** `AttributeError: 'int' object has no attribute 'id'` @ unified_radix_cache.py:2909 loading_check |
| 09-20 23:38 | v4（restamp 已修、hot backup 关）→ 压测 + 看门狗 → **23:44:21 无声僵死**（~2min） |
| 09-21 00:05 | v4fh（v4 + `PYTHONFAULTHANDLER=1`，无代码改动）僵死复现 → SIGABRT 调度器 → **faulthandler 全线程栈落盘**（342 行）→ 根因锁定 |
| 09-21 00:14 | v5 镜像构建（v4 四文件 + lru_file_evictor 三处 hunk 修复 + PYTHONFAULTHANDLER 保留） |
| 09-21 00:20 | v5 canary 起（5803），16 并发压测 + v5b 看门狗（60s 三查 + chat 4-strike + gm>3s 判死） |
| 09-21 00:30 | 首轮"死亡"= **看门狗假阳性**：5-token 探活 20s 超时×3 触发 3-strike。实为 16 并发饱和下探活排在 8 条长生成后排队 10–25s。引擎健康（si 恒 200/0.03–0.07s）。→ v5b 修正判据：chat 超时 20s→60s、3-strike→4-strike |
| 09-21 02:20–02:35 | **v5 2h canary PASS**：1472/1472 fail=0、si 0.015–0.05s、gm 0.002s、L3 83→85%、RAM 82–83G、无 faulthandler dump、无第二自旋线程 |
| 09-21 07:57–08:12 | **四卡滚动 rollout v5**（5800→5801→5802 逐卡，5803 已在位）：每卡独立健康门（si=200，≤3min）+ SMG 重注册 + 冒烟 + 60s 稳定窗，全绿无中止（~15min） |
| 09-21 08:22–08:53 | **两卡压测终判**（5800+5802，16 并发×30min，直连引擎端口绕 SMG）：各 **400/400 fail=0**；si=16ms、gm=2.6ms（远低于 3s 僵尸阈值）；调度主线程 97–98%（高负载正常），备份线程 10–11%（**未钉死**）→ 驱逐器活锁未复现 |
| 09-21 08:53 | **终判：v5 定案为现役生产**。回滚锚 = `sglang:dflash2-ttl-tier4-tclook-0917` |

---

## 三、根因（v4fh faulthandler 栈实锤）

### 3.1 自旋栈（backup 线程，最旧帧在最下）

```
File ".../srt/mem_cache/storage/file/lru_file_evictor.py", line 413 in _score
File ".../lru_file_evictor.py", line 380 in <lambda>
File ".../lru_file_evictor.py", line 379 in _evict_one_lru_locked
File ".../lru_file_evictor.py", line 426 in _evict_while
File ".../lru_file_evictor.py", line 442 in _evict_locked
File ".../lru_file_evictor.py", line 212 in reserve
File ".../srt/mem_cache/hicache_storage.py", line 530 in set
File ".../hicache_storage.py", line 679 in _write_page
File ".../hicache_storage.py", line 702 in _batch_io_v2
File ".../hicache_storage.py", line 719 in batch_set_v2
File ".../srt/mem_cache/hybrid_cache/hybrid_cache_controller.py", line 690 in _page_backup
File ".../hybrid_cache_controller.py", line 751 in backup_thread_func
```

### 3.2 同栈另一异常

- **prefetch 线程**卡 `_collect_existing_component_keys`（hicache_storage.py:594）← `batch_exists_v2`(617) ← `_storage_hit_query`(588) ← `prefetch_thread_func`(cache_controller.py:1207)——同一把 `self._lock` 上的等待者。
- **调度器主线程**当时 mid-forward（dflash_worker_v2.py:1761 ← scheduler.py:4094 run_batch ← 1895 event_loop_overlap），在等一个**永不返回的 L3/D→H ack**（backup 线程死转，D→H 事件队列永不推进）。

### 3.3 机理链

1. v2 把 `_evict_one_lru_locked` 从 O(1) 头弹改成 O(n) 全索引热度扫描（`min(committed, key=_score)`，`_score` 读 `_meta` 热度元组）；
2. `_evict_while` 每成功驱逐一次就 `attempts_left = len(self._lru)` 重置跳过预算；
3. L3 近满（100G×0.9=90G 目标，实测 84–85%）+ write_back 降级压力 → 每次 `reserve()` 需驱逐大量条目才能腾出空间；
4. → 单次 `reserve()` = 多分钟 O(k·n) 扫描风暴，backup 线程 100% CPU 钉死；
5. → L3 写停摆 → D→H ack 永不完成 → 调度主循环挂死 → **僵尸签名**：容器 Up、HTTP 200（uvicorn 独立线程）、引擎死、`/get_model_info` 快（不走死路径）。

### 3.4 A/B 闭环（同 16 并发、同 write_back 策略，单变量=补丁代码）

| 镜像 | hot L3 backup | restamp bug | 结局 |
|---|---|---|---|
| v2 | 开 | 有 | 无声僵死 ~4–5min |
| v3 | 关 | 有 | 7s 硬崩 `AttributeError`（unified_radix_cache.py:2909 loading_check） |
| v4 | 关 | 修 | 无声僵死 ~2min |
| v4fh | 关 | 修 | 同上 + faulthandler 栈（纯取证件） |
| **tclook-0917 基线** | 无 | 无 | **存活**（b=187/192/195 全绿） |

⇒ 根因锁定 **v2 补丁代码层**。write_back flag 本身无罪（老镜像带它活着）。次要嫌疑（hit 统计 O(1)、abort 写回、restamp 调用点）**栈上无踪迹，全部排除**。

### 3.5 特性废弃声明（"之前的 kv 相关"）

- **hot L3 backup 废弃**：v2 在调度主循环每 60s 挑"热 L1-only 节点"做 D→H 拷贝的特性（`maybe_hot_l3_backup`，scheduler.py 两处调用 + unified_radix_cache.py 实现）。它是 v2 家族的头号嫌疑方向，A/B 中 v3/v4 关掉它后仍死，证明它不是根因；但**作为独立特性本身被废弃**——生产保持 off（`getattr(tree_cache, "maybe_hot_l3_backup", None)` no-op 门控）。代码留在 v5 三件文件中仅为与 760 现役镜像字节一致。
- **保留**：write_back 写策略（launch-awq.sh）、热度驱逐（v5 有界版）、L3 奥腾盘布局。

---

## 四、v5 修复（唯一改动文件：`lru_file_evictor.py`，三处 hunk）

| # | 位置 | 改动 |
|---|---|---|
| 1 | `_evict_one_lru_locked` | 全扫描 → **64 窗口有界热度扫描**：`itertools.islice(self._lru.items(), 64)`，跳 `_pending_writes`，窗口内取 `_score` 最小。`touch()` 把每次读回移到 MRU 尾 → 热文件永不进最旧 64 窗口，窗口里只剩冷文件，评分区分度保留 |
| 2 | `_evict_while` | 加**单次调用 256 驱逐硬上限**（`evictions < 256`）：远水位差也不能把一次 `reserve()` 变成多分钟风暴 |
| 3 | `_evict_while` | `evictions += 1` 计数（可观测） |

镜像级附加：`ENV PYTHONFAULTHANDLER=1` 烘进 v5 镜像——**若将来再僵死，`kill -ABRT <调度器 pid>` 直接落全线程栈，免重建取证镜像**。

**语义边界（设计取舍）**：256 上限意味着一次 `reserve()` 最多驱逐 256 个文件；L3 全满且目标差 >256×单文件大小（~10MB）时，本次写入被优雅拒掉（`not caching`，功能降级非稳定性问题）。实测 L3 满时 mamba 78MB 大块备份被挡 → 优雅跳过，小 KV 碎片（~40KB）正常缓存，backup 线程 CPU 可忽略。

---

## 五、验证链

### 5.1 v5 2h canary（5803，09-21 00:20–02:35，PASS）

- 压测：16 并发直连 :5803，**total=1472 ok=1472 fail=0**；batch_wall 全程 64–89s 平稳无退化
- 看门狗 2h 全绿：si 0.015–0.05s、gm 0.002s、chat 全 200（v5b 判据）
- L3 83→85%（未触顶）、RAM 82–83G、**无 faulthandler dump、无第二自旋线程**
- 对照：v2 死 ~4–5min / v4 死 ~2min / **v5 全绿 2h**

### 5.2 看门狗假阳性教训（v5 → v5b）

16 并发饱和下，5-token 探活排在 8 条长生成（2048–4096 tok）之后，排队 10–25s 骑跨 20s 超时 → 3-strike 误判死。线程级 CPU 仅调度器 100%（正常单线程忙），无第二钉死线程。
**修正**：chat 超时 20s→60s、3-strike→4-strike；si 挂死 / chat 500 / gm>3s / 容器死仍立即判死（这些是硬签名，不放宽）。`scripts/canary-watchdog.sh` 已按 v5b 判据入库。

### 5.3 四卡滚动 rollout（07:57–08:12，全绿）

`v5-rollout.sh`（已入库为 `scripts/10-rolling-rollout.sh`）：5800→5801→5802 逐卡，每卡 = SMG 摘 worker → launch-awq.sh 重拉 → si=200 健康门（≤3min）→ SMG 重注册 → 冒烟 chat → 60s 稳定窗 → 复查。~15min 完成，无中止。

### 5.4 两卡压测终判（08:22–08:53，PASS）

5800+5802 各 16 并发×30min，**直连引擎端口绕 SMG**（避免 sessionkey 粘滞打到别的卡）：

| 卡 | total | ok | fail | si | gm | 备份线程 CPU |
|---|---:|---:|---:|---:|---:|---:|
| 5800 | 400 | 400 | 0 | 200/16ms | 200/2.6ms | 10.1% |
| 5802 | 400 | 400 | 0 | 200/16ms | 200/2.5ms | 10.8% |

调度主线程 97–98%（生成满载正常值），**备份线程 10–11% 未钉死** → 驱逐器活锁未复现。`scripts/stress-16c.py` + `scripts/monitor-stress.sh` 已入库。

---

## 六、副作用与坑（本次迭代顺带发现/修掉）

### 6.1 SMG autoreg 竞态（影响后续所有 rollout）

- **现象**：rollout 脚本的 SMG 重注册检查只 `sleep 10`，短于 `autoreg_watch`（run-router.sh 宿主 30s 循环）周期 → 5801/5802 在 autoreg 抢先前被脚本**裸 POST**（body 只有 `{"url":...}`，无 model_id/api_key）→ 登记为 `model=unknown, is_healthy=False` → SMG 实际将其**排除出路由**（仅 5800/5803 在服务）。5800 因 autoreg 先一步拿到全元数据而正常。
- **为何会一直坏**：`autoreg_watch` 只做两件事——「补漏」（live 但未注册 → POST 全元数据）与「删死」（端口不可达 → DELETE）。**它不修复已存在的坏登记** → 裸 POST 的 worker 永远坏下去。
- **修复（已验证）**：DELETE 坏 worker（5801/5802）→ autoreg 下一 30s tick 用全元数据重注册（5801→50b7a5be、5802→fdb43f3f，均 healthy=True / model=qwen3.8）。
- **教训（写入 runbook）**：rollout 的 SMG 检查窗口必须 ≥ autoreg 周期（≥30s）；或摘卡后**不自己裸 POST**，等 autoreg 自动补；或直接用 `bash gateway/run-router.sh register`（`/v1/models` 实查 model_id + api_key 全元数据 POST）。`scripts/10-rolling-rollout.sh` 已按此实现（sleep 35 + 全元数据兜底 POST）。

### 6.2 僵尸卡鉴别三查（历史教训保留，当前 v5 下已不复现）

同签名"HTTP 活/引擎死"若**将来再现**（属新根因，直接 SIGABRT 抓栈对照本文 §三）：
1. `/server_info` 是否挂死（000/超时）——僵尸卡挂，健康卡 <100ms
2. `/get_model_info` 是否 >3s——僵尸卡快（盲区：探活用它，抓不到死引擎）
3. chat 是否 500 "No CUDA GPUs are available"
4. nvidia-smi VRAM 是否被死进程占住（~64GB 不释放）
5. 线程级 CPU：`ps -L -o tid,pcpu,comm -p <scheduler_pid>` 看是否有**第二个** 100% 线程（=驱逐活锁签名）

### 6.3 探活端点盲区（待拍板项）

网关健康检查仍走 `/get_model_info`（底延迟 5ms，09-10 A3 治本换端点所得）。该端点**抓不到死引擎**（僵尸卡时仍 200/快）。防御纵深选项：改 `/health_generate`（真实 forward，能抓引擎死）。**未动**——v5 下僵尸签名已消除，改动收益待新证据。

---

## 七、复现与排查手册

```bash
# 复现旧死法（v2/v4 镜像）：16 并发直连 + L3 ≥85%
PORT=5803 CONCURRENCY=16 DURATION=7200 python3 scripts/stress-16c.py
# 抓栈（v5+ 镜像自带 PYTHONFAULTHANDLER=1）：
kill -ABRT <scheduler 主线程 pid>   # faulthandler 落全线程栈，对照 §3.1 自旋点
# 僵尸三查：
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:5803/server_info
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:5803/get_model_info
# 滚动 rollout 新镜像：
SGLANG_IMG=<new-tag> bash scripts/10-rolling-rollout.sh
```

**回滚锚**：`sglang:dflash2-ttl-tier4-tclook-0917`（09-17 版，O(1) 头弹驱逐器，无 v2 补丁家族）

---

## 八、本次迭代产物清单（已入本仓库）

| 产物 | 位置 |
|---|---|
| 0007 补丁（4 整文件 == 760 v5 现役树） | `sglang/patches/0007-v5-heat-evictor/` |
| 构建（0007 块 + G5 md5 门 + G6 冒烟 + PYTHONFAULTHANDLER） | `sglang/Dockerfile.prod` |
| 起服脚本同步（write_back + L3 奥腾盘 + 真 200 判活） | `sglang/launch-awq.sh` |
| 网关脚本同步（autoreg_watch + wait_for_workers + 09-19 镜像默认） | `gateway/run-router.sh` |
| 滚动 rollout（每卡健康门 + autoreg 竞态对策） | `scripts/10-rolling-rollout.sh` |
| canary 看门狗（v5b 判据：60s/4-strike/gm>3s） | `scripts/canary-watchdog.sh` |
| 16 并发压测（直连引擎，绕 SMG） | `scripts/stress-16c.py` |
| 压测伴随监控（僵尸早断 + 自旋线程检查） | `scripts/monitor-stress.sh` |
| 本报告 | `docs/v2-v5-zombie-evictor-20260921.md` |
