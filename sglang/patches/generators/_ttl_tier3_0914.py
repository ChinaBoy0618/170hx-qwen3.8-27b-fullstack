#!/usr/bin/env python3
"""Tiered KV eviction — tier3 (2026-09-14): activate the ttl_watermark sweep
on the class the engine ACTUALLY runs.

ROOT CAUSE (verified 3 ways: startup log impl=UnifiedRadixCache; grep shows
ttl_watermark_enabled only on HiRadixCache; 10-min idle tail @99.6% with zero
reclaim). Qwen3.8-27B is a hybrid SSM/mamba model whose tree cache is
UnifiedRadixCache, a SIBLING of HiRadixCache (both inherit BasePrefixCache).
create_tree_cache never routes to HiRadixCache. Consequence: the tier1/tier2
active watermark sweep is INERT for this model — ttl_watermark_enabled is
never set, _ttl_token_usage doesn't exist, and the sweep's guard returns early.
The +310K "eviction" in the 09-14 fill was passive on-alloc LRU, not the
tier2 sweep.

tier3 makes the ACTIVE 75/80/90% reclaim real on UnifiedRadixCache (3 edits):

  1. unified_radix_cache.__init__: set ttl_watermark_enabled from
     params.eviction_policy == "ttl_watermark" (production value).

  2. unified_radix_cache._ttl_token_usage: read 1 - available/total from the
     shared allocator (size_full / available_size both exist on the
     multi-ended allocator).

  3. scheduler._maybe_ttl_watermark_reclaim: class-agnostic total read —
     fall back to token_to_kv_pool_allocator.size_full when the cache has no
     .kv_cache (UnifiedRadixCache has none; the bare .kv_cache.size raised
     AttributeError, silently swallowed by except:pass).

evict(EvictParams(num_tokens=...)) already exists on UnifiedRadixCache and the
unified tree core skips lock_ref>0 components before device eviction, so the
new proactive sweep cannot evict in-flight request KV.

Phase 2 (deferred): per-node expire_at/tier stamping on the unified tree core
gives tier-1 12h hot-cap and precise 30min/5min countdown ordering. Until
then eviction ordering is LRU-oldest, which still satisfies the user's
"evict oldest X%" wording for tiers 2/3/4.

Idempotent: re-run is a no-op if the tier3 markers are present. Unique anchor
assertion per edit; clean .bak-0914-tier3 backups kept.
"""
import py_compile
import shutil
import sys
from pathlib import Path

BASE = Path("/mnt/data/sglang-qwen38/sglang-src-0519-ttl/python/sglang/srt")
STAMP = ".bak-0914-tier3"

edits: dict[str, list[tuple[str, str]]] = {}

# ---------------------------------------------------------------- unified_radix_cache.py
# Edit 1: expose ttl_watermark_enabled so the scheduler sweep guard passes.
edits["mem_cache/unified_radix_cache.py"] = [
    (
        "        self.disable = params.disable\n"
        "\n"
        "        if params.enable_metrics:\n",
        "        self.disable = params.disable\n"
        "        self.ttl_watermark_enabled = (\n"
        "            (params.eviction_policy or \"lru\").lower() == \"ttl_watermark\"\n"
        "        )\n"
        "\n"
        "        if params.enable_metrics:\n",
    ),
    # Edit 2: give the class a working usage readout (sweep calls this).
    (
        "    def _all_reduce_attn_groups(self, tensor: torch.Tensor, op):\n",
        "    def _ttl_token_usage(self) -> float:\n"
        "        \"\"\"True pool occupancy (includes evictable radix tokens).\"\"\"\n"
        "        try:\n"
        "            total = self.token_to_kv_pool_allocator.size_full\n"
        "            avail = self.token_to_kv_pool_allocator.available_size()\n"
        "            return 1.0 - avail / total if total > 0 else 0.0\n"
        "        except Exception:\n"
        "            return 0.0\n"
        "\n"
        "    def _all_reduce_attn_groups(self, tensor: torch.Tensor, op):\n",
    ),
]

# ---------------------------------------------------------------- scheduler.py
# Edit 3: class-agnostic total read (UnifiedRadixCache has no .kv_cache).
edits["managers/scheduler.py"] = [
    (
        "            total = tree_cache.kv_cache.size\n"
        "            if usage >= 0.90:\n",
        "            kv = getattr(tree_cache, \"kv_cache\", None)\n"
        "            total = (\n"
        "                kv.size\n"
        "                if kv is not None\n"
        "                else tree_cache.token_to_kv_pool_allocator.size_full\n"
        "            )\n"
        "            if usage >= 0.90:\n",
    ),
]

MARKERS = {
    "mem_cache/unified_radix_cache.py": "self.ttl_watermark_enabled = (",
    "managers/scheduler.py": "kv = getattr(tree_cache, \"kv_cache\", None)",
}


def main() -> int:
    for rel, pairs in edits.items():
        path = BASE / rel
        text = path.read_text(encoding="utf-8")
        if MARKERS[rel] in text:
            print(f"SKIP [{rel}] tier3 marker already present (idempotent)")
            continue
        for i, (old, new) in enumerate(pairs):
            n = text.count(old)
            if n != 1:
                print(f"FAIL [{rel}] edit#{i}: anchor hit {n} times (expect 1)")
                return 1
            text = text.replace(old, new, 1)
        if not path.with_name(path.name + STAMP).exists():
            shutil.copy2(path, path.with_name(path.name + STAMP))
        path.write_text(text, encoding="utf-8")
        print(f"OK   [{rel}] {len(pairs)} edit(s)")

    for rel in edits:
        py_compile.compile(str(BASE / rel), doraise=True)
    print("SYNTAX OK — tier3 (UnifiedRadixCache activation) applied; rebuild image + canary")
    return 0


if __name__ == "__main__":
    sys.exit(main())
