#!/bin/bash
# 760T 全 GPU 统一启动脚本: AWQ-W4A16 (EfficientThink SFT+SimPO) 原生262144 + DFLASH + HiCache ratio + toolfix/keepalive 补丁 + chat_template
# 09-12 AWQ 生产切换版: 派生自 launch-int8.sh(原脚本已备份 pre-awq-cutover-20260912/launch-int8.sh.bak-20260912)。
# 与 INT8 版 delta 仅 3 处: MODEL 换 AWQ-W4A16; +env HF_HUB_OFFLINE/TRANSFORMERS_OFFLINE/AWQ_SGLANG_VIDEO_DECODER;
#   +--dtype bfloat16 (均为 canary 已验证项)。其余逐字一致。
# 09-13: 健康检查后新增 CC 前缀自暖(WARM_CC=1 默认): 把 CC 桌面端默认前缀(≈24.6K tok)
#   灌进本卡 radix, 新 CC 会话首 turn ≈95% 命中(23.4K/24.6K), TTFT 15s→~0.5s。
#   载荷: /mnt/data/sglang-qwen38/cc-warm/warm-cc-prefix.json; 失败不阻断起服; 回滚 WARM_CC=0。
#   注: 已移除 --trust-remote-code(用户安全考量, 09-12); 本 checkpoint 无自定义 modeling_*.py,
#       且与生产同架构(Qwen3_5ForConditionalGeneration)在 int8 版下无需该 flag 即可加载。
#       若 card-1 canary 因缺该 flag 加载失败, 回滚并重加。
# 用法: SGLANG_HICACHE_RATIO=1.0 bash launch-awq.sh <容器名> <GPU> <宿主端口> <served-model-name>...
# 示例: SGLANG_HICACHE_RATIO=1.0 bash launch-awq.sh qwen38-27b-gpu0 0 5801 qwen3.8
# 回滚: SGLANG_HICACHE_RATIO=1.5 bash launch-int8.sh <容器名> <GPU> <宿主端口> qwen3.8
set -uo pipefail
NAME="${1:?容器名}"; GPU="${2:?GPU编号}"; PORT="${3:?宿主端口}"; shift 3
[ $# -ge 1 ] || { echo "至少一个 served-model-name"; exit 1; }
MODEL=/mnt/data/models/eff-awq-w4a16/NVFP4/AWQ-W4A16
DRAFT="${SGLANG_DRAFT_PATH:-/mnt/data/models/Qwen3.8-27B-DFlash2}"
IMG="${SGLANG_IMG:-sglang:dflash2-ttl-tier4}"
KEY="${SGLANG_API_KEY:?need to export SGLANG_API_KEY (see .env.example)}"
CTX="${SGLANG_CTX_LEN:-262144}"; RATIO="${SGLANG_HICACHE_RATIO:-1.0}"; KA_SECS=30; CHUNK="${SGLANG_CHUNK_PREFILL:-8192}"; MEM_FRAC="${SGLANG_MEM_FRACTION:-0.9}"; EXTRA_ARGS="${SGLANG_EXTRA_ARGS:---radix-eviction-policy ttl_watermark --enable-metrics}"; L3_ENABLE="${SGLANG_L3:-0}"; KV_DTYPE="${SGLANG_KV_CACHE_DTYPE:-fp8_e4m3}"; DRAFT_KV="${SGLANG_DRAFT_KV_CACHE_DTYPE:-fp8_e4m3}"; L3_DIR="${SGLANG_L3_DIR:-/mnt/nvme-kv/kv-l3/gpu${GPU%%,*}}"; L3_MAX="${SGLANG_L3_MAX_GB:-100G}"; [ "$L3_ENABLE" != "1" ] && { L3_DIR=""; L3_MAX=""; }; case "$EXTRA_ARGS" in *hicache-storage-backend*) ;; *) [ "$L3_ENABLE" = "1" ] && EXTRA_ARGS="$EXTRA_ARGS --hicache-storage-backend file" ;; esac; KV_DTYPE="${SGLANG_KV_CACHE_DTYPE:-fp8_e4m3}"; DRAFT_KV="${SGLANG_DRAFT_KV_CACHE_DTYPE:-fp8_e4m3}"   # 09-13 L3 on by default; SGLANG_L3=0 to disable (09-14 fix: L3 logic was dead after a mid-line # comment; moved before it)
: ${KV_DTYPE:=fp8_e4m3}; : ${DRAFT_KV:=fp8_e4m3}   # 09-03 belt-and-suspenders: case/esac bug under set -u
TKW="${SGLANG_TOK_WORKERS:-4}"   # 09-11: tokenizer frontend workers (CPU); auth patch 已挂载可安全 >1; 回滚: SGLANG_TOK_WORKERS=1
PATCH_DIR=/mnt/data/sglang-qwen38/keepalive-patch
TPL=$PATCH_DIR/chat_template-fix.jinja
CONT_FILE=/sgl-workspace/sglang-main/python/sglang/srt/entrypoints/openai/serving_chat.py
BK=/mnt/data/sglang-qwen38/hicache-cmd-backup; mkdir -p "$BK"
[ -f "$TPL" ] || { echo "missing $TPL"; exit 1; }
[ -f "$MODEL/config.json" ] || { echo "missing $MODEL/config.json"; exit 1; }
[ -f "$DRAFT/config.json" ] || { echo "missing $DRAFT/config.json"; exit 1; }; DRAFT_BS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dflash_config",{}).get("block_size",8))' "$DRAFT/config.json" 2>/dev/null) || DRAFT_BS=8; DRAFT_BS=${DRAFT_BS:-8}; echo "[qwen38] draft block_size=$DRAFT_BS"
SPEC_DISABLE="${SGLANG_SPEC_DISABLE:-0}"   # 09-08 DFlash2 on/off A/B switch (default 0=keep DFlash2)
SPEC_ARGS=(); SPEC_DRAFT_MOUNT=(); SPEC_KV_ARGS=()
if [ "$SPEC_DISABLE" != "1" ]; then
  SPEC_ARGS+=(--speculative-algorithm DFLASH --speculative-draft-model-path /draft --speculative-num-draft-tokens "$DRAFT_BS")
  SPEC_DRAFT_MOUNT+=(-v "$DRAFT":"/draft:ro")
  SPEC_KV_ARGS+=(--speculative-draft-kv-cache-dtype "$DRAFT_KV")
fi
echo "[qwen38] spec_disable=$SPEC_DISABLE"
MN_OPTS=(); for mn in "$@"; do MN_OPTS+=(--served-model-name "$mn"); done
L3_DIR="${L3_DIR:-}"; L3_MOUNT=(); [ -n "$L3_DIR" ] && L3_MOUNT+=(-v "$L3_DIR":"$L3_DIR")
VB_SRC=/mnt/data/sglang-qwen38/verify-budget-patch/dflash_worker_v2.py
VB_DST=/sgl-workspace/sglang-main/python/sglang/srt/speculative/dflash_worker_v2.py
VB_MOUNT=(); [ "${SGLANG_VERIFY_BUDGET_PATCH:-0}" = "1" ] && VB_MOUNT+=(-v "$VB_SRC":"$VB_DST":ro)
VB_ENV=(); [ "${SGLANG_VERIFY_BUDGET_PATCH:-0}" = "1" ] && [ -n "${SGLANG_DFLASH_VERIFY_BUDGET:-}" ] && VB_ENV+=(-e "SGLANG_DFLASH_VERIFY_BUDGET=${SGLANG_DFLASH_VERIFY_BUDGET}")
# 09-12 DFLASH WNA16 fused-KV dequant patch: opt-in bind-mount of 3 patched sglang files.
#   仅当 SGLANG_DFLASH_PATCH=1 时挂载(canary 用); 默认不影响生产卡。回滚: 不设该 env 即可。
DFLASH_PATCH=()
if [ "${SGLANG_DFLASH_PATCH:-0}" = "1" ]; then
  DFLASH_PATCH=(
    -v "$PATCH_DIR/dflash_utils.py":"/sgl-workspace/sglang-main/python/sglang/srt/speculative/dflash_utils.py":ro
    -v "$PATCH_DIR/dflash.py":"/sgl-workspace/sglang-main/python/sglang/srt/models/dflash.py":ro
    -v "$PATCH_DIR/fused_kv_materialize.py":"/sgl-workspace/sglang-main/python/sglang/kernels/ops/speculative/fused_kv_materialize.py":ro
  )
fi
# 09-11 cpuset: 每卡 4 逻辑线程(=2 物理核 + HT 兄弟, sibling(i)=i+10, lscpu 已核实),
#   宿主服务(网关/监控/dify/comfyui/frpc) 恒留 8,9,18,19。硬顶而非 --cpus 软配额(后者均值节流会冻 GIL scheduler)。
#   回滚: SGLANG_CPUSET=none 重拉该卡(不绑核)。
case "$GPU" in
  0) CPUSET="0-1,10-11" ;;
  1) CPUSET="2-3,12-13" ;;
  2) CPUSET="4-5,14-15" ;;
  3) CPUSET="6-7,16-17" ;;
  *) CPUSET="" ;;
esac
CPUSET="${SGLANG_CPUSET:-$CPUSET}"; [ "$CPUSET" = "none" ] && CPUSET=""
CPUS_ARGS=(); [ -n "$CPUSET" ] && CPUS_ARGS+=(--cpuset-cpus "$CPUSET"); echo "[qwen38] cpuset=$CPUSET"
# 09-11 parallel-toolfix guard: 确保挂载的 serving_chat.py 含补丁(cutover 换版易丢, 幂等补打)。
#   所有走本脚本的路径(canary/cutover/resume/普通重启)在 docker run 前都会检查并补打;
#   补丁失配则中止启动, 不带病起服。
if ! grep -q "09-11 hardened" "$PATCH_DIR/serving_chat.py" 2>/dev/null; then
  echo "[qwen38] parallel-toolfix 缺失, 补打..."
  cp -p "$PATCH_DIR/serving_chat.py" "$PATCH_DIR/serving_chat.py.pre-patch-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  ( cd "$PATCH_DIR" && patch -p0 serving_chat.py < serving_chat-parallel-toolfix.patch ) || {
    echo "[qwen38] ERROR: parallel-toolfix 补丁应用失败, 中止启动"; exit 1;
  }
  echo "[qwen38] parallel-toolfix 已补打"
fi
# 09-11 tkw-auth guard: 挂载源 http_server.py 必须含 tkw-auth 补丁(多tokenizer+api-key 需补丁, 否则启动断言中止)。
HS=$PATCH_DIR/http_server.py
if ! grep -q "09-11 tkw-auth" "$HS" 2>/dev/null; then
  echo "[qwen38] tkw-auth 补丁缺失, 补打..."
  cp -p "$HS" "$PATCH_DIR/http_server.py.pre-tkw-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  ( cd "$PATCH_DIR" && patch -p0 http_server.py < http_server-tkw-auth.patch ) || {
    echo "[qwen38] ERROR: tkw-auth 补丁应用失败, 中止启动"; exit 1;
  }
  echo "[qwen38] tkw-auth 已补打"
fi
docker inspect -f "{{json .Config.Cmd}}" "$NAME" > "$BK/${NAME}.pre-launch0827.json" 2>/dev/null || true
docker rm -f "$NAME" 2>/dev/null || true
for i in $(seq 1 30); do
  used=$(nvidia-smi -i "${GPU%%,*}" --query-gpu=memory.used --format=csv,noheader | grep -o "[0-9]*")
  [ "${used:-99999}" -le 2048 ] && break; sleep 2
done
docker run -d --name "$NAME" \
  --gpus "\"device=$GPU\"" --shm-size 32g --ipc=host ${CPUS_ARGS[@]+"${CPUS_ARGS[@]}"} -p "$PORT":8000 \
  -v "$MODEL":/model:ro ${SPEC_DRAFT_MOUNT[@]+"${SPEC_DRAFT_MOUNT[@]}"} \
  -v "$PATCH_DIR/serving_chat.py":"$CONT_FILE":ro \
  -v "$PATCH_DIR/http_server.py":"/sgl-workspace/sglang-main/python/sglang/srt/entrypoints/http_server.py":ro \
  -v "$TPL":/chat-template-fix.jinja:ro \
  -v /mnt/data/sglang-jit-cache:/root/.cache/sglang \
  ${L3_MOUNT[@]+"${L3_MOUNT[@]}"} \
  ${VB_MOUNT[@]+"${VB_MOUNT[@]}"} \
  ${DFLASH_PATCH[@]+"${DFLASH_PATCH[@]}"} \
  ${VB_ENV[@]+"${VB_ENV[@]}"} \
  --restart unless-stopped -e SGLANG_SKIP_SGL_KERNEL_VERSION_CHECK=1 -e SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK="${SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK:-1}" \
  -e SGLANG_STREAM_KEEPALIVE_SECS="$KA_SECS" -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  -e SGLANG_HICACHE_FILE_BACKEND_STORAGE_DIR="${L3_DIR:-}" -e SGLANG_HICACHE_FILE_BACKEND_MAX_SIZE="${L3_MAX:-}" \
  -e OMP_NUM_THREADS=4 -e OPENBLAS_NUM_THREADS=4 -e MKL_NUM_THREADS=4 -e VECLIB_MAXIMUM_THREADS=1 -e TOKENIZERS_PARALLELISM=FALSE \
  -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e AWQ_SGLANG_VIDEO_DECODER=decord \
  "$IMG" python3 -m sglang.launch_server \
    --model-path /model --dtype bfloat16 \
    ${SPEC_ARGS[@]+"${SPEC_ARGS[@]}"} \
    --tokenizer-worker-num "$TKW" \
    --context-length "$CTX" --mem-fraction-static "$MEM_FRAC" --chunked-prefill-size "$CHUNK" \
    --max-running-requests 8 --cuda-graph-max-bs 16 --disable-prefill-cuda-graph $EXTRA_ARGS \
    --host 0.0.0.0 --port 8000 --api-key "$KEY" \
    --kv-cache-dtype "$KV_DTYPE" ${SPEC_KV_ARGS[@]+"${SPEC_KV_ARGS[@]}"} \
    --max-mamba-cache-size 32 --mamba-ssm-dtype bfloat16 \
    ${MN_OPTS[@]+"${MN_OPTS[@]}"} \
    --reasoning-parser qwen3 --tool-call-parser qwen3_coder \
    --chat-template /chat-template-fix.jinja \
    --enable-hierarchical-cache --hicache-ratio "$RATIO" --hicache-write-policy write_through --enable-cache-report
# 09-10 guard: docker run 失败(如端口冲突)时容器会停在 Created,
#   旧检查会 curl 到同端口的其他活容器误报 HEALTHY。先验状态再等健康。
sleep 2
_st=$(docker inspect -f "{{.State.Status}}" "$NAME" 2>/dev/null || echo missing)
if [ "$_st" != "running" ]; then
  echo "[$NAME] docker run FAILED: state=$_st"
  docker inspect -f "{{.State.Error}}" "$NAME" 2>/dev/null | sed "s/^/  err: /"
  exit 1
fi
echo "[$NAME] launched :$PORT (gpu $GPU, ctx=$CTX, patched), waiting health..."
ok=0
for i in $(seq 1 90); do
  sleep 10
  curl -s -m 3 "http://localhost:$PORT/health" >/dev/null 2>&1 && { ok=1; echo "[$NAME] HEALTHY"; break; }
  docker inspect -f "{{.State.Status}}" "$NAME" 2>/dev/null | grep -q exited && { echo "[$NAME] EXITED!"; docker logs --tail 8 "$NAME" 2>&1 | tail -8; exit 1; }
done
[ $ok -eq 1 ] || echo "[$NAME] TIMEOUT"
# 09-13 CC 前缀自暖: 把 CC 桌面端默认前缀(≈24.6K tok)灌进本卡 radix,
#   新 CC 会话首 turn ≈95% 命中, TTFT 15s→~0.5s。失败不阻断起服; 回滚 WARM_CC=0。
if [ "${WARM_CC:-1}" = "1" ]; then
  WARM_JSON=/mnt/data/sglang-qwen38/cc-warm/warm-cc-prefix.json
  if [ -f "$WARM_JSON" ]; then
    # 09-13 双暖: pass1 建枝(hit_count=1, write_through 已落 host) → pass2 复用同枝
    #   hit_count=2 → ttl_watermark 自动晋升 tier2(L1 共享前缀, 最后被逐) + 12h TTL。
    #   单暖只到 tier1(压力下来会先被逐); 双暖才拿到"最后淘汰 + 12h"。
    w1=$(curl -s -m 120 -X POST "http://localhost:$PORT/v1/messages" \
        -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
        -d @"$WARM_JSON" > /dev/null 2>&1; echo $?)
    w2=$(curl -s -m 120 -X POST "http://localhost:$PORT/v1/messages" \
        -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
        -d @"$WARM_JSON" > /dev/null 2>&1; echo $?)
    if [ "$w1" = "0" ] && [ "$w2" = "0" ]; then
      echo "[$NAME] cc-prefix warmed (2-pass: tier2 + host)"
      # tier4: pin the warmed prefix so it is never evicted
      pin_resp=$(curl -s -m 10 -X POST "http://localhost:${PORT}/admin/pin_prefix" -H "Authorization: Bearer $KEY")
      echo "[$NAME] pin_prefix: $pin_resp"
    else
      echo "[$NAME] cc-prefix warm incomplete (w1=$w1 w2=$w2, non-fatal)"
    fi
  else
    echo "[$NAME] cc-prefix warm skipped (missing $WARM_JSON)"
  fi
fi
free -g | head -2
