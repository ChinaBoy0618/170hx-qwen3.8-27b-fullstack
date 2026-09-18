#!/bin/bash
# dl-effthink.sh — Merkyor EfficientThink 微调模型三档下载（INT8-QAT / AWQ-W4A16 / FP8）
# 来源: ModelScope Merkyor/Qwen3.8-27B-EfficientThink-K3-Opus5-Grok4.6-GPT5.6Sol-SFT-SimPO-DFlash2
# 用法: nohup bash dl-effthink.sh > dl-effthink.nohup 2>&1 &
set -u
R="Qwen3.8-27B-EfficientThink-K3-Opus5-Grok4.6-GPT5.6Sol-SFT-SimPO-DFlash2"
BASE="https://www.modelscope.cn/models/Merkyor/$R/resolve/master"
M=/mnt/data/models

avail() { df -BG --output=avail /mnt/data | tail -1 | tr -dc 0-9; }
log() { echo "[$(date +%T)] $*"; }

fetch() { # $1=local-variant-dir  $2=remote-relpath
  local v="$1" r="$2" d="$M/$1/$2"
  [ -f "$d" ] && return 0
  mkdir -p "$(dirname "$d")"
  if curl -sfL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$d.part" "$BASE/$r"; then
    mv -f "$d.part" "$d"
  else
    rm -f "$d.part"
    log "FAIL $v $r"
    return 1
  fi
}

verify() { # $1=local-variant-dir
  local v="$1" out
  [ -f "$M/$v/SHA256SUMS" ] || { log "$v: 无 SHA256SUMS，跳过校验"; return 1; }
  out=$(cd "$M/$v" && sha256sum -c SHA256SUMS 2>&1)
  echo "$out" > "$M/$v.sha256log"
  if echo "$out" | grep -q "FAILED"; then log "$v: SHA256 不匹配"; return 1; fi
  log "$v: sha256 OK（$(echo "$out" | grep -c ': OK') files OK）"
}

dl_int8() {
  local v=eff-int8-qat r="NVFP4/INT8-W8A8-QAT/" f
  for f in chat_template.jinja config.json generation_config.json manifest.json merges.txt \
    model-00001-of-00008.safetensors model-00002-of-00008.safetensors model-00003-of-00008.safetensors \
    model-00004-of-00008.safetensors model-00005-of-00008.safetensors model-00006-of-00008.safetensors \
    model-00007-of-00008.safetensors model-00008-of-00008.safetensors model.safetensors.index.json \
    preprocessor_config.json SHA256SUMS tokenizer.json tokenizer_config.json \
    vision-mtp-bf16.safetensors video_preprocessor_config.json vocab.json \
    evaluation/formal-quality-and-performance.json \
    runtime/sglang-sm120-int8-compat/manifest.json \
    runtime/sglang-sm120-int8-compat/night_triton_scaled_mm.py \
    runtime/sglang-sm120-int8-compat/sitecustomize.py \
    scripts/serve-sglang-bare.sh scripts/serve-sglang-mtp3.sh \
    scripts/serve-vllm-bare.sh scripts/serve-vllm-mtp3.sh; do
    fetch "$v" "$r$f" || return 1
  done
  verify "$v" && log "INT8 DONE $(date +%T)"
}

dl_awq() {
  local v=eff-awq-w4a16 r="NVFP4/AWQ-W4A16/" f
  for f in chat_template.jinja config.json generation_config.json hf_quant_config.json manifest.json \
    merges.txt model.safetensors.index.json PACKAGE_MANIFEST.json preprocessor_config.json \
    Qwen3.8-27B-EfficientThink-SimPO-AWQ-W4A16.safetensors SHA256SUMS SOURCE_SHA256SUMS \
    tokenizer.json tokenizer_config.json vision-mtp-bf16.safetensors video_preprocessor_config.json \
    vocab.json runtime/README.md runtime/START_SGLANG0519_AWQ_W4A16_PATCHED.sh \
    runtime/START_VLLM028_AWQ_W4A16.sh runtime/video_decoder.patch; do
    fetch "$v" "$r$f" || return 1
  done
  verify "$v" && log "AWQ DONE $(date +%T)"
}

dl_fp8() {
  local v=eff-fp8 r="FP8/" f
  for f in chat_template.jinja config.json generation_config.json manifest.json merges.txt \
    model-00001-of-00008.safetensors model-00002-of-00008.safetensors model-00003-of-00008.safetensors \
    model-00004-of-00008.safetensors model-00005-of-00008.safetensors model-00006-of-00008.safetensors \
    model-00007-of-00008.safetensors model-00008-of-00008.safetensors model.safetensors.index.json \
    mtp-bf16.safetensors SHA256SUMS tokenizer.json tokenizer_config.json vocab.json \
    DFlash2-FP8/config.json DFlash2-FP8/manifest.json DFlash2-FP8/model.safetensors DFlash2-FP8/SHA256SUMS \
    runtime/BUILD_RUNTIME_SPARK.sh runtime/Dockerfile.spark runtime/fetch_runtime.py \
    runtime/runtime.lock.json runtime/TESTED_STARTUP_C24_DFLASH2.sh; do
    fetch "$v" "$r$f" || return 1
  done
  verify "$v" && log "FP8 DONE $(date +%T)"
}

log "start avail=$(avail)G"
[ "$(avail)" -ge 88 ] || { log "ABORT: /mnt/data 空闲 <88G，拒绝下载"; exit 1; }
dl_int8 & p1=$!
dl_awq  & p2=$!
dl_fp8  & p3=$!
wait $p1; r1=$?
wait $p2; r2=$?
wait $p3; r3=$?
log "RESULT int8=$r1 awq=$r2 fp8=$r3 avail=$(avail)G"
[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && [ $r3 -eq 0 ] && log "ALL DONE"
