# models/ — 权重下载与校验

## 主模型

- **Qwen3.8-27B AWQ-W4A16**（EfficientThink SFT+SimPO + DFlash2）
  - 来源: ModelScope `Merkyor/Qwen3.8-27B-EfficientThink-K3-Opus5-Grok4.6-GPT5.6Sol-SFT-SimPO-DFlash2`
  - 760 落点: `/mnt/data/models/eff-awq-w4a16/NVFP4/AWQ-W4A16/`
  - quantization_config: compressed-tensors int4 / group 128 (W4A16)
  - 视觉塔: BF16 未量化（`ignore: re:.*visual.*`）

## Draft 模型

- **Qwen3.8-27B-DFlash2**
  - 760 落点: `/mnt/data/models/Qwen3.8-27B-DFlash2/`
  - `block_size = 8`（对应 `--speculative-num-draft-tokens 8`）

## 下载与校验

```bash
bash models/dl-effthink.sh        # 下载（含 HF_HUB_OFFLINE 前置检查）
sha256sum -c SHA256SUMS           # 校验权重完整性
```

`SHA256SUMS` 覆盖 AWQ 主权重全部分片 + vision-mtp 附属文件。
