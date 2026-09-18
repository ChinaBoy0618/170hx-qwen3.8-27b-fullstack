#!/usr/bin/env python3
"""Tiered KV eviction — tier2 tuning (2026-09-12).

Refines the ALREADY-DEPLOYED `ttl_watermark` eviction policy so it matches the
user's exact 4-tier spec. Targets the TTL-patched 0.5.19 production tree
(sglang-src-0519-ttl). Production image is rebuilt from this tree, so a canary
card must be verified before any rollout.

Two functions are retuned (everything else in the ttl patch stays as-is):

  HiRadixCache._ttl_secs_for_usage
      per-node retention TTL, stamped from current pool usage:
        <35%  -> 12h   (hot band, 25-35% of pool)
        <75%  -> 4h    (session band, unchanged)
        <80%  -> 30min (>75% countdown)          [was 75-85%:30min]
        <90%  -> 5min  (>80% countdown)          [NEW]
        >=90% -> 0     (>90% immediate)          [NEW]

  Scheduler._maybe_ttl_watermark_reclaim
      active watermark sweep (runs <=1x / 5s at scheduler loop tail):
        <75%  -> no-op
        75-80 -> small graded nudge (TTL drives the rest)
        80-90 -> reclaim oldest ~22.5% (20-25%)   [was: small at 85-90]
        >=90  -> immediately reclaim oldest 35%    [was: clear down to <85%]

The "countdown" is realized by the per-node expire_at TTL + the ttl_watermark
ordering (expired nodes pop first from the min-heap); the sweep just triggers
eviction when usage crosses a band. Inert unless the engine runs with
--radix-eviction-policy ttl_watermark (already the production value).

Idempotent: re-running is a no-op if the tier2 markers are already present.
Each edit asserts a unique anchor hit; a clean .bak-0912-tier2 is kept.
"""
import py_compile
import shutil
import sys
from pathlib import Path

BASE = Path("/mnt/data/sglang-qwen38/sglang-src-0519-ttl/python/sglang/srt")
STAMP = ".bak-0912-tier2"

edits: dict[str, list[tuple[str, str]]] = {}

# ---------------------------------------------------------------- hiradix_cache.py
# Retention TTL bands: split the old 75-85%:30min into 75-80%:30min and
# 80-90%:5min, and add >=90%:0 (immediate).
edits["mem_cache/hiradix_cache.py"] = [
    (
        "        if usage < 0.35:\n"
        "            return 43200  # L1 band (25-35%): 12h\n"
        "        if usage < 0.75:\n"
        "            return 14400  # L2 band (65-75%): 4h\n"
        "        if usage < 0.85:\n"
        "            return 1800  # L3 band (80-85%): 30min\n"
        "        return 180  # L4 (>85%): reclaimable within 3min",
        "        if usage < 0.35:\n"
        "            return 43200  # hot band (25-35%): 12h\n"
        "        if usage < 0.75:\n"
        "            return 14400  # session band: 4h\n"
        "        if usage < 0.80:\n"
        "            return 1800  # >75%: 30min countdown\n"
        "        if usage < 0.90:\n"
        "            return 300  # >80%: 5min countdown\n"
        "        return 0  # >90%: immediate reclaim",
    ),
]

# ---------------------------------------------------------------- scheduler.py
# Active watermark reclaim: lower the start band to 75%, and use the user's
# explicit fractions (20-25% at 80%, 35% at 90%).
edits["managers/scheduler.py"] = [
    (
        "            usage = tree_cache._ttl_token_usage()\n"
        "            if usage < 0.85:\n"
        "                return\n"
        "            from sglang.srt.mem_cache.base_prefix_cache import EvictParams\n"
        "\n"
        "            total = tree_cache.kv_cache.size\n"
        "            if usage >= 0.90:\n"
        "                # immediate: reclaim oldest non-hot down to <85%\n"
        "                target = max(0.0, usage - 0.84) * total\n"
        "            else:\n"
        "                # graded reclaim within the 3-minute window: evict\n"
        "                # expired / L3-tier first, bounded chunks per pass\n"
        "                target = max(0.0, (usage - 0.85) * 0.20) * total\n"
        "            if target >= 1:\n"
        "                tree_cache.evict(EvictParams(num_tokens=int(target)))",
        "            usage = tree_cache._ttl_token_usage()\n"
        "            if usage < 0.75:\n"
        "                return\n"
        "            from sglang.srt.mem_cache.base_prefix_cache import EvictParams\n"
        "\n"
        "            total = tree_cache.kv_cache.size\n"
        "            if usage >= 0.90:\n"
        "                # >90%: immediately reclaim oldest 35%\n"
        "                target = 0.35 * total\n"
        "            elif usage >= 0.80:\n"
        "                # >80%: reclaim oldest ~22.5% (20-25%)\n"
        "                target = 0.225 * total\n"
        "            else:\n"
        "                # 75-80%: small graded nudge (TTL drives the rest)\n"
        "                target = max(0.0, (usage - 0.75) * 0.20) * total\n"
        "            if target >= 1:\n"
        "                tree_cache.evict(EvictParams(num_tokens=int(target)))",
    ),
]

MARKERS = {
    "mem_cache/hiradix_cache.py": "return 300  # >80%: 5min countdown",
    "managers/scheduler.py": "target = 0.225 * total",
}


def main() -> int:
    for rel, pairs in edits.items():
        path = BASE / rel
        text = path.read_text(encoding="utf-8")
        if MARKERS[rel] in text:
            print(f"SKIP [{rel}] tier2 markers already present (idempotent)")
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
    print("SYNTAX OK — tier2 tuning applied; rebuild image + canary before rollout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
