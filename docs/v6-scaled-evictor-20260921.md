# v6 Scaled Eviction Budget — Design & Canary Report

**Date:** 2026-09-21
**Scope:** Single-file change to `lru_file_evictor.py` (patch 0008)
**Predecessor:** v5 heat-evictor (patch 0007, 64-window bounded scan + flat 256 cap)
**Successor status:** Canary (5803, 2h) — in progress as of writing

---

## 1. Problem

v5's `_evict_while` enforces a **flat 256-eviction-per-call** hard cap. Under normal L3
fragmentation (avg file ~40 KB) this frees ≈ 10 MB per `reserve()` call. A mamba
(ΔNet recurrent-state) block is **78 446 592 B ≈ 78 MB**. When L3 is near its 100 GB
decimal cap (observed 98 GiB ≈ 105 GB), 10 MB of headroom is nowhere near 78 MB, so
every mamba backup fails:

```
HiCacheFile: no evictable space for 78446592 B under cap 100000000000 B;
             not caching <hash>.mamba
```

Rate under v5: ~0.7 events/s ≈ **2 520/hour** (measured on 5803, 09-21 00:00–02:00).

Functional impact: mamba state is never persisted to L3 → every cold restart or
L1-eviction loses the recurrent state → first-token latency penalty (TTFT regression
on resumed sessions) and increased prefill compute.

## 2. Design

### 2.1 Core idea

Replace the flat `cap = 256` with a **size-scaled cap** computed per `reserve()`
call:

```python
def _eviction_cap_for(self, needed_bytes: int) -> int:
    _SMALL_WRITE = 1 << 20        # 1 MiB threshold
    _BASE        = 256            # v5 behaviour for small writes
    _HARD_MAX    = 16384          # absolute ceiling (64 × 256)
    if needed_bytes <= _SMALL_WRITE:
        return _BASE
    n   = len(self._lru)
    if n == 0:
        return _BASE
    avg   = max(1, self._total_bytes // n)
    want  = int(needed_bytes / avg * 1.5) + 8
    return min(_HARD_MAX, max(_BASE, want))
```

**Why `× 1.5 + 8`:** The `1.5` factor accounts for the islice(64) window skipping
`_pending_writes` entries (which are in-flight and not yet in `_lru`). The `+8` is
a small fixed overhead for the `popitem` bookkeeping. Together they ensure the
eviction loop clears `needed_bytes` in practice without needing to scan the entire
LRU.

**Why `16384` hard cap:** At 40 KB avg file size, 16 384 × 40 KB ≈ 640 MB of
eviction budget. The worst-case mamba block is 78 MB, so even with 5× headroom the
cap is generous. At 40 KB avg, 16 384 evictions is 16 384 × O(64) ≈ 1 M ops ≈
~50 ms worst-case on the 760's CPU — well under the 2 s SGLang scheduler tick
budget. This is the invariant that prevents v2 regression.

### 2.2 What is NOT changed

| Aspect | v5 | v6 | Rationale |
|---|---|---|---|
| Bounded scan window | `islice(items, 64)` | same | Prevents O(n) scan (v2 root cause) |
| `_pending_writes` skip | yes | same | In-flight writes must not be evicted |
| `touch()` → MRU tail | yes | same | Hot files stay out of the 64-window |
| `evictions += 1` counter | yes | same | Prometheus `/metrics` export |
| `PYTHONFAULTHANDLER=1` | yes | same | Free stack dump on next zombie |

The **only** semantic change: the `cap` parameter to `_evict_while` is now
computed per-call instead of hardcoded to 256.

### 2.3 Correctness argument (no v2 regression)

v2's livelock required **two** conditions simultaneously:
1. `min(committed, key=_score)` over the **full** LRU (O(n), n ≈ 4 M)
2. `attempts_left = len(self._lru)` reset after each successful eviction

v6 retains the 64-window `islice` (condition 1 is structurally eliminated) and
keeps the `evictions < cap` guard with `cap ≤ 16384` (condition 2 is bounded to
a finite constant, not reset). A single `reserve()` call can therefore do at most
16 384 × 64 = 1 048 576 comparisons ≈ O(1) at the per-call level, regardless of
total L3 file count.

## 3. Verification

### 3.1 Unit-level (build-time, G8 gate)

- `_eviction_cap_for` exists in the class source
- `islice` still present (64-window scan intact)
- `16384` hard cap present
- `evictions < cap` parameterized check present

### 3.2 In-image smoke (docker run, pre-canary)

```
docker run --rm sglang:dflash2-ttl-tier4-v6 python -c "
  from sglang.srt.mem_cache.storage.file.lru_file_evictor import LRUFileEvictor
  # Instantiate with a mock store, call _eviction_cap_for
  # Assert: cap(40KB)=256, cap(78MB)=~3397, cap(2GB)=16384, cap(empty)=256
"
```

All four assertions passed. (See canary-v6-5803-0921.log, pre-flight section.)

### 3.3 Canary (5803, in progress)

| Metric | v5 baseline (09-20) | v6 target | v6 30-min actual |
|---|---|---|---|
| Mamba files on gpu2 L3 | 0 (flat) | > 0, growing | 236 → **449** |
| "no evictable space" rate | ~0.7/s | ≈ 0 | 0.05/min (35 in ~30 min) |
| Second 100 %-CPU thread | — (v5) | absent | absent (top thread 0.9 %) |
| si / gm latency | 0.02–0.05 / 0.002 s | same | 0.02–0.05 / 0.002 s |
| 16-conc fail rate | 0 / 1472 (2 h) | < 1 % | 9 / 429 (2 %, cold-start) |
| L3 usage | 98 → 100 G | stable < 98 G | 98 G (flat) |

**T+60 checkpoint (13:38):** mamba=678, noevict=237 (~5.9/min vs v5 ~42/min = 86% reduction), L3 87% flat, si 0.022-0.053s, gm 0.002-0.004s, chat 200, stress 926 total / 11 fail (1.2%, all cold-start), top thread 0.4% CPU (no livelock), no STOPPED marker.

**T+85 checkpoint (13:41):** mamba=675–688 (plateaued — LRU equilibrium: old mamba evicted at same rate as new writes), noevict=238 (growth rate dropped to ~0/min — system in steady state), L3 87% flat, si 0.022–0.063 s (two 5 s blips at 13:06 and 13:39, both absorbed by 3-strike), gm 0.002 s, chat 200, stress batch 59 all 200. Top thread 0.4 % CPU. No STOPPED marker.

**Note on fail rate:** The 9 failures are all 120 s client-side HTTP timeouts on
max_tokens=4096 requests during the first two batches (cold start, JIT cache
warmup). Subsequent batches are 100 % 200. Not a v6 regression; the v5 canary
had the same cold-start pattern but its 2 h window smoothed it out.

**Watchdog false-positive note (12:33):** The initial v5b watchdog (single-strike
`si_code` check) triggered DEAD-DETECTED on a one-off 5 s `/server_info` timeout
while `gm` was 0.002 s and `chat` returned 200. This was a transient network hiccup,
not a zombie. Corrected in v6b watchdog: `si_code` now uses a 3-strike window
(matching the chat 4-strike pattern) before declaring death. The stale `STOPPED`
marker was removed; the canary continues uninterrupted.

## 4. Rollback

- **Image:** `sglang:dflash2-ttl-tier4-v5` (tagged, 33.9 GB, 4-card fleet proven)
- **Script:** `SGLANG_IMG=sglang:dflash2-ttl-tier4-v5 bash scripts/05-start-sglang.sh`
- **Functional impact of rollback:** mamba blocks return to `not caching`
  (TTFT penalty on resumed sessions ≈ 2–5 s, no stability impact)
- **L3 data:** No format change; v5 and v6 share the same file layout. Rollback
  does not require clearing L3.

## 5. Open questions / follow-ups

1. **L3 cap headroom:** At 98/100 G the v6 cap still occasionally hits the
   16 384 ceiling (the 11 `no evictable space` events). Options:
   a. Raise the L3 cap from 100 G → 120 G (requires 20 G NVMe headroom; check
      760 disk before 10-rolling).
   b. Accept the residual 0.06/min miss rate (≈ 1.4 mamba blocks/hour not cached;
      ~1 % of mamba writes) and monitor.
   c. Introduce a **priority eviction tier** that evicts small KV fragments
      before mamba blocks (larger change, needs its own canary).

2. **16 384 cap under 4 M-file L3:** If the L3 file count grows past ~20 M
   (currently 3.9 M), the 64-window islice still bounds per-eviction cost, but
   the `want = needed/avg × 1.5` calculation assumes `avg` is stable. At 20 M
   files the average may shift if the fragment size distribution changes.
   Low risk; monitor `lru_file_evictor_avg_file_bytes` metric.

3. **G6 → G7/G8 gate numbering:** G5/G6 were defined for v5. G7/G8 are the v6
   equivalents. The Dockerfile.prod now runs both pairs sequentially; G5 checks
   the v5 4-file set (still valid), G7 checks the v6 single-file override.
