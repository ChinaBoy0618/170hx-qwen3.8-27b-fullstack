#!/usr/bin/env python3
"""四层 KV 保留策略引擎补丁（A: 分档TTL驱逐 + B: 水位主动回收）。

只改 /mnt/data/sglang-qwen38/sglang-src-ttl（独立树），生产树 sglang-src 与
生产镜像 sglang:dflash2 零接触。每个替换都断言唯一命中，失败即退出非零。
"""
import py_compile
import shutil
import sys
from pathlib import Path

BASE = Path("/mnt/data/sglang-qwen38/sglang-src-ttl/python/sglang/srt")
STAMP = ".bak-0831-ttl"

edits: dict[str, list[tuple[str, str]]] = {}

# ---------------------------------------------------------------- evict_policy.py
edits["mem_cache/evict_policy.py"] = [
    (
        "from __future__ import annotations\n\nfrom abc import ABC, abstractmethod",
        "from __future__ import annotations\n\nimport time\nfrom abc import ABC, abstractmethod",
    ),
    (
        "        is_protected = 1 if node.hit_count >= self.protected_threshold else 0\n        return (is_protected, node.last_access_time)",
        """        is_protected = 1 if node.hit_count >= self.protected_threshold else 0
        return (is_protected, node.last_access_time)


class TTLWatermarkStrategy(EvictionStrategy):
    \"\"\"Tiered-TTL + watermark-aware eviction (four-layer KV retention).

    Ordering key (min-heap pops smallest = evicted first):
      1. alive: expired nodes (0) evicted before alive nodes (1)
      2. tier:  L3/hot-recent (0) < L2/session (1) < L1/shared-prefix (2)
      3. expire_at: sooner-to-expire first (inf = no expiry stamped)
      4. last_access_time: oldest first

    tier/expire_at are stamped by HiRadixCache (_ttl_stamp); nodes that were
    never stamped keep default tier=1/expire_at=None and degrade to plain LRU
    within band 2.
    \"\"\"

    def get_priority(self, node: TreeNode) -> Tuple[int, int, float, float]:
        expire_at = getattr(node, "expire_at", None)
        alive = 1 if (expire_at is None or expire_at > time.monotonic()) else 0
        tier = getattr(node, "tier", 1)
        exp = expire_at if expire_at is not None else float("inf")
        return (alive, tier, exp, node.last_access_time)""",
    ),
]

# ---------------------------------------------------------------- utils.py
edits["mem_cache/utils.py"] = [
    (
        "    PriorityStrategy,\n    SLRUStrategy,\n)",
        "    PriorityStrategy,\n    SLRUStrategy,\n    TTLWatermarkStrategy,\n)",
    ),
    (
        '    "slru": SLRUStrategy,\n}',
        '    "slru": SLRUStrategy,\n    "ttl_watermark": TTLWatermarkStrategy,\n}',
    ),
]

# ---------------------------------------------------------------- server_args.py
edits["server_args.py"] = [
    (
        'RADIX_EVICTION_POLICY_CHOICES = ["lru", "lfu", "slru", "priority"]',
        'RADIX_EVICTION_POLICY_CHOICES = ["lru", "lfu", "slru", "priority", "ttl_watermark"]',
    ),
]

# ---------------------------------------------------------------- radix_cache.py
edits["mem_cache/radix_cache.py"] = [
    (
        "        # priority for priority-aware eviction\n        self.priority = priority",
        "        # priority for priority-aware eviction\n        self.priority = priority\n"
        "        # tiered-TTL retention (ttl_watermark policy): 0=L3 hot-recent,\n"
        "        # 1=L2 session, 2=L1 shared-prefix; None expire_at = not stamped\n"
        "        self.tier = 1\n        self.expire_at = None",
    ),
]

# ---------------------------------------------------------------- hiradix_cache.py
edits["mem_cache/hiradix_cache.py"] = [
    # enable flag on the cache
    (
        "        self.write_through_threshold = (\n"
        "            1 if server_args.hicache_write_policy == \"write_through\" else 2\n"
        "        )\n"
        "        self.load_back_threshold = 10",
        "        self.write_through_threshold = (\n"
        "            1 if server_args.hicache_write_policy == \"write_through\" else 2\n"
        "        )\n"
        "        self.load_back_threshold = 10\n"
        "        self.ttl_watermark_enabled = (\n"
        "            params.eviction_policy.lower() == \"ttl_watermark\"\n"
        "        )",
    ),
    # helpers + stamping on hit (fan-in -> L1)
    (
        "    def _inc_hit_count(self, node: TreeNode, chunked=False):",
        """    # ---- TTL watermark (tiered retention) helpers ----
    def _ttl_secs_for_usage(self, usage: float) -> int:
        # watermark bands -> retention TTL (confirmed semantics: retention
        # shrinks as GPU KV pool usage rises)
        if usage < 0.35:
            return 43200  # L1 band (25-35%): 12h
        if usage < 0.75:
            return 14400  # L2 band (65-75%): 4h
        if usage < 0.85:
            return 1800  # L3 band (80-85%): 30min
        return 180  # L4 (>85%): reclaimable within 3min

    def _ttl_token_usage(self) -> float:
        try:
            total = self.kv_cache.size
            avail = self.token_to_kv_pool_allocator.available_size()
            return 1.0 - avail / total if total > 0 else 0.0
        except Exception:
            return 0.0

    def _ttl_stamp(self, node: TreeNode, promote: bool = False) -> None:
        \"\"\"Stamp/refresh tier + expire_at. promote=True upgrades the node to
        L1 (shared prefix, fan-in signal: another request hit the same node).\"\"\"
        if not self.ttl_watermark_enabled:
            return
        if promote and node.tier < 2:
            node.tier = 2
        node.expire_at = time.monotonic() + self._ttl_secs_for_usage(
            self._ttl_token_usage()
        )

    def _inc_hit_count(self, node: TreeNode, chunked=False):""",
    ),
    (
        "        node.hit_count += 1\n\n        if not node.backuped:",
        "        node.hit_count += 1\n"
        "        # hit_count>=2 means another request reuses this node -> shared prefix (L1)\n"
        "        self._ttl_stamp(node, promote=(node.hit_count >= 2))\n\n        if not node.backuped:",
    ),
    # stamp newly inserted leaf nodes (robust also for chunked/write_back)
    (
        "        if len(key):\n"
        "            new_node = TreeNode(priority=priority)\n"
        "            new_node.parent = node\n"
        "            new_node.key = key\n"
        "            new_node.value = value.clone()",
        "        if len(key):\n"
        "            new_node = TreeNode(priority=priority)\n"
        "            new_node.parent = node\n"
        "            new_node.key = key\n"
        "            new_node.value = value.clone()\n"
        "            self._ttl_stamp(new_node)",
    ),
    # propagate tier on split
    (
        "        new_node.key = child.key[:split_len]\n        new_node.hit_count = child.hit_count",
        "        new_node.key = child.key[:split_len]\n"
        "        new_node.hit_count = child.hit_count\n"
        "        new_node.tier = child.tier\n"
        "        new_node.expire_at = child.expire_at",
    ),
]

# ---------------------------------------------------------------- scheduler.py
edits["managers/scheduler.py"] = [
    # the watermark reclaimer itself
    (
        "    def on_idle(self):",
        """    def _maybe_ttl_watermark_reclaim(self):
        \"\"\"Watermark-driven active reclaim (layer 4 of the tiered retention).

        Passive eviction only fires on allocation failure; this adds the
        watermark trigger: >85% graded reclaim (expired/L3 first, via the
        ttl_watermark eviction ordering), >90% immediate clear of the oldest
        non-hot entries down to <85%. Inert unless the engine runs with
        --radix-eviction-policy ttl_watermark.
        \"\"\"
        tree_cache = getattr(self, "tree_cache", None)
        if tree_cache is None or not getattr(
            tree_cache, "ttl_watermark_enabled", False
        ):
            return
        now = time.monotonic()
        if now - getattr(self, "_ttl_wm_last_check", 0.0) < 5.0:
            return
        self._ttl_wm_last_check = now
        try:
            usage = tree_cache._ttl_token_usage()
            if usage < 0.85:
                return
            from sglang.srt.mem_cache.base_prefix_cache import EvictParams

            total = tree_cache.kv_cache.size
            if usage >= 0.90:
                # immediate: reclaim oldest non-hot down to <85%
                target = max(0.0, usage - 0.84) * total
            else:
                # graded reclaim within the 3-minute window: evict
                # expired / L3-tier first, bounded chunks per pass
                target = max(0.0, (usage - 0.85) * 0.20) * total
            if target >= 1:
                tree_cache.evict(EvictParams(num_tokens=int(target)))
        except Exception:
            pass

    def on_idle(self):""",
    ),
    # hook: normal loop tail
    (
        "            # Update last_batch\n"
        "            self.last_batch = batch\n"
        "            if envs.SGLANG_ENABLE_STRICT_MEM_CHECK_DURING_BUSY.get():",
        "            # Update last_batch\n"
        "            self.last_batch = batch\n"
        "            self._maybe_ttl_watermark_reclaim()\n"
        "            if envs.SGLANG_ENABLE_STRICT_MEM_CHECK_DURING_BUSY.get():",
    ),
    # hook: overlap loop tail (blank line between last_batch and envs check)
    (
        "            # Update last_batch\n"
        "            self.last_batch = batch\n\n"
        "            if envs.SGLANG_ENABLE_STRICT_MEM_CHECK_DURING_BUSY.get():",
        "            # Update last_batch\n"
        "            self.last_batch = batch\n\n"
        "            self._maybe_ttl_watermark_reclaim()\n"
        "            if envs.SGLANG_ENABLE_STRICT_MEM_CHECK_DURING_BUSY.get():",
    ),
]


def main() -> int:
    for rel, pairs in edits.items():
        path = BASE / rel
        text = path.read_text(encoding="utf-8")
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
    print("SYNTAX OK — all patched files compile")
    return 0


if __name__ == "__main__":
    sys.exit(main())
