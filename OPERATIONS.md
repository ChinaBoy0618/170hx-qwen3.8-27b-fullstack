# OPERATIONS.md — Day-2 运维手册

> 日常巡检、告警响应、canary / cutover / 回滚 runbook、会话路由运维、事故索引。

---

## 一、日常巡检

### 1.1 一键全链路检查

```bash
bash scripts/verify/v1-sglang.sh      # 4 卡推理层
bash scripts/verify/v2-gateway.sh     # 网关路由 + 会话粘滞
bash scripts/verify/v3-newapi.sh      # new-api
bash scripts/verify/v4-cc-warm.sh     # CC 前缀缓存
bash scripts/verify/v5-monitoring.sh  # 监控栈
```

### 1.2 手动快速探测

```bash
# SGLang worker health（4 卡）
for p in 5800 5801 5802 5803; do
  echo -n "  :$p /health -> "
  curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:$p/health"
done

# SMG 网关
curl -s http://127.0.0.1:30010/health
# 控制面 worker 列表（需 CP key）
curl -s -H "Authorization: Bearer $CP_KEY" http://127.0.0.1:30010/workers

# new-api
curl -s http://127.0.0.1:3001/api/status

# 监控
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c \
  "import sys,json; [print(t['labels'].get('job','?'), t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
curl -s http://127.0.0.1:3000/api/health
```

### 1.3 GPU 状态

```bash
nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv
```

---

## 二、看门狗 / 告警

### 2.1 Prometheus 告警规则

配置文件：`monitoring/rules.yml`（由 `launch-observability.sh` 挂入 `760-prometheus`）

| 告警名 | 条件 | 说明 |
|---|---|---|
| `SGLangWorkerDown` | `/get_model_info` 连续 3 次超时 | worker 探活失败 |
| `GPUUtilizationHigh` | GPU 利用率 > 95% 持续 5 min | 过载预警 |
| `GPUTemperatureHigh` | GPU 温度 > 83°C | 硬件保护 |
| `KVCacheFull` | KV 池使用率 > 95% | 驱逐风暴风险 |
| `PrefixCacheMiss` | CC 前缀命中率 < 99% | 双暖失效 |
| `GatewayWorkerRemoved` | SMG 摘除 worker 事件 | 路由异常 |

### 2.2 飞书告警

`monitoring/feishu-watch.py`：轮询 Prometheus alertmanager → 飞书 webhook
配置文件：`monitoring/env/feishu.env`（chmod 400，不入 git）

---

## 三、Grafana 面板地图

Dashboard：`sglang-760`（uid=`sglang-760`）
面板 JSON：`monitoring/grafana/dashboards/sglang-760.json`

| Panel ID | 名称 | 位置 (x) | 说明 |
|---|---|---|---|
| 20 | 运行状态（按卡） | — | 4 卡 SGLang 容器状态 + GPU 利用率 |
| 102 | 排队 / 积压 | — | 按卡：pending / in-flight requests |
| 103 | 收回 / 驱逐 | — | 按卡：KV 驱逐事件、prefix hit rate |
| 21 | 吞吐 (tok/s) | x=12 | 按卡：decode tok/s |
| 22 | 延迟 (TTFT / FRP) | x=16 | 按卡：TTFT p50/p90/p99, FRP |
| 23 | KV 池使用 | x=20 | 按卡：KV pool usage / evictable |
| 53 | 路由分布 (SMG) | — | 按 worker：request count / load |

**按卡固定配色**：5800 = 蓝、5801 = 绿、5802 = 橙、5803 = 红

---

## 四、Canary / Cutover / 回滚 Runbook

### 4.1 Canary（单卡验证）

```bash
# 1. 备份当前镜像 tag
docker tag <current-image> <current-image>.pre-canary-$(date +%Y%m%d)

# 2. 构建新镜像
bash scripts/01-build-sglang.sh    # 或对应组件 build 脚本

# 3. 单卡 canary（以 gpu0 / 5801 为例）
SGLANG_IMG=<new-tag> bash sglang/launch-awq.sh qwen38-canary 0 5801 qwen3.8

# 4. 验证
bash scripts/verify/v1-sglang.sh

# 5. 对比基线（吞吐 / 延迟 / KV 命中率 / accept rate）
```

**门禁**：
- accept rate ≥ 基线 − 5%
- TTFT p99 ≤ 基线 + 20%
- 无新增 OOM / 崩溃

### 4.2 Cutover（全量切换）

**首选：滚动 rollout 脚本**（09-21 起，含每卡健康门 + SMG 重注册 + 稳定窗，~15min/4卡）：

```bash
SGLANG_IMG=<new-tag> bash scripts/10-rolling-rollout.sh
# 可选: CARDS="0 1 2" 只滚部分卡；5803 等已在位的卡会自动跳过
```

脚本内建对策（勿手工裸 POST SMG，见 §5.4 竞态）：每卡 = 摘 worker → 重拉 → `/server_info`=200 健康门（≤3min）→ **等 ≥35s 让 autoreg 先补全元数据**（短于 autoreg 30s 周期的裸 POST 会登记出 model=unknown 坏 worker）→ 兜底全元数据 POST → 冒烟 chat → 60s 稳定窗。

<details><summary>手工逐卡（仅脚本不可用时）</summary>

```bash
for gpu in 0 1 2 3; do
  SGLANG_IMG=<new-tag> bash sglang/launch-awq.sh \
    "qwen38-27b-gpu${gpu}" "$gpu" "$((5800 + gpu))" qwen3.8
  sleep 120
done
```

</details>

全链验证：

```bash
bash scripts/verify/v1-sglang.sh
bash scripts/verify/v2-gateway.sh
bash scripts/verify/v4-cc-warm.sh
```

### 4.3 僵尸卡应急（HTTP 活 / 引擎死）

```bash
# 三查（任一异常即僵尸）:
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 5 http://127.0.0.1:5800/server_info     # 须 <1s 200
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -m 5 http://127.0.0.1:5800/get_model_info  # >3s 可疑
# 线程级: ps -L -o tid,pcpu,comm -p <scheduler_pid>  看是否有第二个 100% 线程
# v5+ 镜像自带 PYTHONFAULTHANDLER=1: kill -ABRT <scheduler_pid> 直接落全线程栈
# 复活: SGLANG_IMG=<现役> bash sglang/launch-awq.sh <容器> <gpu> <port> qwen3.8 + SMG 重注册
```

详见 `docs/v2-v5-zombie-evictor-20260921.md`（含鉴别签名与 v5 前自旋栈）。

### 4.4 回滚

| 组件 | 回滚方法 | 回滚锚 |
|---|---|---|
| SGLang | `SGLANG_IMG=<old-tag> bash scripts/05-start-sglang.sh` | 生产 tag 保留在 docker images |
| SMG 网关 | `bash gateway/run-router.sh restart`（恢复旧配置） | `.bak-cacheaware-0917` |
| new-api | 重建旧版本镜像并启动 | 旧镜像 tag |
| 参数回滚 | 改 `.env` 对应变量 → 重启对应组件 | 变更记录见 `TUNING.md` |

**回滚原则**：
- 每次生产变更必须有回滚锚（旧镜像 tag / 旧脚本备份 / 旧参数快照）
- 回滚后必须重跑 v1-v5 全链验证
- 回滚操作记录到下方事故索引

---

## 五、会话路由运维

### 5.1 路由表管理

```bash
# 查看当前路由表
cat /mnt/data/sglang-qwen38/gw-data/session-routing.json | jq .

# 清除路由表（慎用：丢失所有会话粘滞）
echo '{}' > /mnt/data/sglang-qwen38/gw-data/session-routing.json

# 路由表自动快照：60s 原子写，4h TTL 自动清理过期会话
```

### 5.2 路由 key 优先级

1. `x-smg-routing-key`（显式指定 worker）
2. `x-claude-code-session-id`（CC 会话粘滞）
3. `c:xxh3(前 8192 字符)`（内容哈希，非会话场景缓存亲和）
4. `min_load`（无 key 时按最小 load 分配）

### 5.3 常见路由问题

| 症状 | 排查 | 处置 |
|---|---|---|
| 同会话落不同 worker | 检查 session-routing.json 是否被清 / TTL 过期 | 重路由或延长 TTL |
| 单卡过载 | 检查 min_load 是否生效 / 路由表是否锁定 | 清除路由表或手动 re-register |
| 路由表膨胀 | 检查 TTL 配置 | 缩短 TTL 或手动清理 |

### 5.4 SMG autoreg 竞态（rollout 必读）

`run-router.sh watch` 的 `autoreg_watch` 每 30s 一轮，只做两件事：**补漏**（live 但未注册 → 全元数据 POST）与**删死**（端口不可达 → DELETE），**不修复已存在的坏登记**。

- **坑**：rollout 摘卡后若自己 `POST /workers` 只带 `{"url":...}`（无 model_id/api_key），会抢在 autoreg 之前把 worker 登记成 `model=unknown, is_healthy=False`，SMG 随即把它排除出路由；且 autoreg 不会修复这个坏登记 → 该卡一直坏下去。
- **对策**（三选一，`10-rolling-rollout.sh` 已实现）：
  1. 摘卡后**不自己裸 POST**，等 autoreg 下一 30s tick 自动补全元数据（故脚本 SMG 检查窗 ≥35s）；
  2. 或直接用 `bash gateway/run-router.sh register`（`/v1/models` 实查 model_id + api_key 全元数据 POST）；
  3. 若已产生坏登记：`DELETE /workers/<id>` 删掉，等 autoreg 下一 tick 重注册。

---

## 六、事故索引

| 日期 | 事故 | 根因 | 处置 | 回滚锚 |
|---|---|---|---|---|
| 09-08 | TTFT 劣化 | 网关 busy 卡误摘（/health 底延迟 1 s + 长 prefill 8-15 s vs 超时 5 s） | 换 /get_model_info 端点 + 放宽 cb 10/60 | `.bak-0909-hc-tune` |
| 09-10 | new-api i/o timeout | bridge → host 网络 hairpin NAT 对 host-network 容器端口规则不全 | 改 host 网络直连 127.0.0.1:30010 | 脚本备份 |
| 09-16 | ratio 1.5 扩容失败 | RAM 硬约束（256 GB 宿主，4 卡 KV 池已满） | 维持 ratio = 1.0 | — |
| 09-17 | 5803 僵尸卡 | mamba assert 崩后 HTTP 层存活；/get_model_info 探活盲区 + 粘滞 = 12 会话持续 2×600 s 挂死 | 重启 5803（随 tc-lookahead 四卡全滚） | — |
| 09-17 | thinking 内工具标签泄漏 | Qwen3Detector 在 thinking 阶段看到 tool tag 即关闭推理块 | 0006 tc-lookahead 补丁 | `sglang:dflash2-ttl-tier4`（无 0006） |
| 09-20 | v2 四卡僵尸卡（无声僵死） | v2 补丁把 L3 驱逐 `_evict_one_lru_locked` 改 O(n) 全索引扫描 + `_evict_while` 每次驱逐重置 `attempts_left` → L3 近满 + write_back 下 `reserve()` 变多分钟 O(k·n) 风暴 → backup 线程 100% 钉死 → D→H ack 不完成 → 调度主循环挂死（v4fh faulthandler 全线程栈实锤） | 0007 v5 驱逐器：64 窗口有界扫描 + 单次 256 驱逐硬上限 + `PYTHONFAULTHANDLER=1`；四卡滚动 rollout v5 | `sglang:dflash2-ttl-tier4-tclook-0917` |
| 09-21 | rollout 5801/5802 掉出路由 | SMG autoreg 竞态：rollout 裸 POST 抢在 30s autoreg 前，登记 model=unknown/is_healthy=False，autoreg 不修坏登记 | DELETE 坏 worker → autoreg 下一 tick 全元数据重注册；`10-rolling-rollout.sh` 内建 ≥35s 等待 + 全元数据兜底 | — |
