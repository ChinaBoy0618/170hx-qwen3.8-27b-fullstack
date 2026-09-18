#!/usr/bin/env python3
"""Tiered KV eviction — tier3b (phase 2, 2026-09-14): per-node TTL stamping on
the UnifiedRadixCache path.

tier3 activated the watermark sweep on UnifiedRadixCache (the class the engine
actually runs); this patch adds the per-node expire_at/tier stamping so the
TTLWatermarkStrategy stops degrading to plain LRU:

  1. UnifiedTreeCore.__init__: add ``self._ttl_stamper = None`` hook.
  2. UnifiedTreeCore._new_node: stamp every newly created cache node.
  3. UnifiedTreeCore._inc_hit_count_and_check: re-stamp (refresh countdown)
     on each hit; promote tier 1 -> 2 at hit_count >= 2 (shared-prefix
     protection), mirroring HiRadixCache._ttl_stamp(promote=...).
  4. UnifiedTreeCore._split_node: inherit tier/expire_at from the split-off
     child (mirrors HiRadixCache node-split behavior).
  5. UnifiedRadixCache: port _ttl_secs_for_usage (4-tier bands) + _ttl_stamp
     from HiRadixCache, and wire the stamper after tree_core creation.

Semantics (same as tier1/tier2 design, now live on the unified path):
  <35%  -> 12h   (hot band)
  <75%  -> 4h    (session band)
  <80%  -> 30min
  <90%  -> 5min
  >=90% -> 0     (immediate)

TTLWatermarkStrategy.get_priority (evict_policy.py) already reads
getattr(node, "expire_at", None) / getattr(node, "tier", 1); nothing to change
there. UnifiedTreeNode has no __slots__, so attribute stamping is safe.

Idempotent: re-run is a no-op if the tier3b markers are present.
"""
import py_compile
import shutil
import sys
from pathlib import Path

BASE = Path("/mnt/data/sglang-qwen38/sglang-src-0519-ttl/python/sglang/srt")
STAMP = ".bak-0914-tier3b"

edits: dict[str, list[tuple[str, str]]] = {}

# ---------------------------------------------------------------- unified_tree_core.py
edits["mem_cache/unified_cache/unified_tree_core.py"] = [
    # 1. stamper hook field
    (
        "        self.eviction_strategy = get_eviction_strategy(params.eviction_policy.lower())\n",
        "        self.eviction_strategy = get_eviction_strategy(params.eviction_policy.lower())\n"
        "        # Optional TTL-stamp callback (set by the cache when\n"
        # --radix-eviction-policy ttl_watermark). None = plain LRU.\n"
        "        self._ttl_stamper = None\n",
    ),
    # 2. stamp on node creation
    (
        "        node = UnifiedTreeNode(self.component_types, priority=priority)\n"
        "        self._register_node(node)\n"
        "        return node\n",
        "        node = UnifiedTreeNode(self.component_types, priority=priority)\n"
        "        if self._ttl_stamper is not None:\n"
        "            self._ttl_stamper(node, promote=False)\n"
        "        self._register_node(node)\n"
        "        return node\n",
    ),
    # 3. re-stamp on hit (refresh countdown; promote shared prefixes)
    (
        "        node.hit_count += 1\n"
        "\n"
        "        if self.enable_external_cache_linker:\n",
        "        node.hit_count += 1\n"
        "        if self._ttl_stamper is not None:\n"
        "            self._ttl_stamper(node, promote=(node.hit_count >= 2))\n"
        "\n"
        "        if self.enable_external_cache_linker:\n",
    ),
    # 4. split inherits tier/expire_at
    (
        "        new_node.hit_count = child.hit_count\n"
        "        new_node.external_cache_stored = child.external_cache_stored\n"
        "        new_node.creation_time = child.creation_time\n",
        "        new_node.hit_count = child.hit_count\n"
        "        new_node.external_cache_stored = child.external_cache_stored\n"
        "        new_node.creation_time = child.creation_time\n"
        "        new_node.tier = getattr(child, \"tier\", 1)\n"
        "        new_node.expire_at = getattr(child, \"expire_at\", None)\n",
    ),
]

# ---------------------------------------------------------------- unified_radix_cache.py
edits["mem_cache/unified_radix_cache.py"] = [
    # 5a. port _ttl_secs_for_usage + _ttl_stamp (after _ttl_token_usage from tier3)
    (
        "            return 1.0 - avail / total if total > 0 else 0.0\n"
        "        except Exception:\n"
        "            return 0.0\n"
        "\n"
        "    def _all_reduce_attn_groups(self, tensor: torch.Tensor, op):\n",
        "            return 1.0 - avail / total if total > 0 else 0.0\n"
        "        except Exception:\n"
        "            return 0.0\n"
        "\n"
        "    def _ttl_secs_for_usage(self, usage: float) -> int:\n"
        "        # watermark bands -> retention TTL (retention shrinks as pool fills)\n"
        "        if usage < 0.35:\n"
        "            return 43200  # hot band (25-35%): 12h\n"
        "        if usage < 0.75:\n"
        "            return 14400  # session band: 4h\n"
        "        if usage < 0.80:\n"
        "            return 1800  # >75%: 30min countdown\n"
        "        if usage < 0.90:\n"
        "            return 300  # >80%: 5min countdown\n"
        "        return 0  # >90%: immediate reclaim\n"
        "\n"
        "    def _ttl_stamp(self, node, promote: bool = False) -> None:\n"
        "        \"\"\"Stamp/refresh tier + expire_at (TTLWatermarkStrategy reads\n"
        "        both via getattr). promote=True upgrades a re-hit shared prefix\n"
        "        to tier 2 (evicted last). No-op unless ttl_watermark is on.\n"
        "        \"\"\"\n"
        "        if not self.ttl_watermark_enabled:\n"
        "            return\n"
        "        try:\n"
        "            if promote and getattr(node, \"tier\", 1) < 2:\n"
        "                node.tier = 2\n"
        "            node.expire_at = time.monotonic() + self._ttl_secs_for_usage(\n"
        "                self._ttl_token_usage()\n"
        "            )\n"
        "        except Exception:\n"
        "            pass\n"
        "\n"
        "    def _all_reduce_attn_groups(self, tensor: torch.Tensor, op):\n",
    ),
    # 5b. wire the stamper after tree_core creation
    (
        "        # Components execute boundary actions through the tree core.\n"
        "        for component in self.components.values():\n"
        "            component.tree_core = self.tree_core\n",
        "        # Components execute boundary actions through the tree core.\n"
        "        for component in self.components.values():\n"
        "            component.tree_core = self.tree_core\n"
        "        # TTL countdown stamping on node create/hit (no-op unless\n"
        "        # ttl_watermark is the active policy).\n"
        "        self.tree_core._ttl_stamper = self._ttl_stamp\n",
    ),
]

MARKERS = {
    "mem_cache/unified_cache/unified_tree_core.py": "self._ttl_stamper = None",
    "mem_cache/unified_radix_cache.py": "def _ttl_secs_for_usage",
}


def main() -> int:
    for rel, pairs in edits.items():
        path = BASE / rel
        text = path.read_text(encoding="utf-8")
        if MARKERS[rel] in text:
            print(f"SKIP [{rel}] tier3b marker already present (idempotent)")
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
    print("SYNTAX OK — tier3b (node TTL stamping) applied; rebuild image")
    return 0


if __name__ == "__main__":
    sys.exit(main())
