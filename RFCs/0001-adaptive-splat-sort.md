# RFC 0001 — Adaptive Splat Sort (Insertion-from-Previous-Frame)

- **Status:** Rejected (experiment failed)
- **Date:** 2026-04-07
- **Author:** jwight
- **Related commits:** `wpyovoqx d092ea5b` (adaptive sort), `srmkmxut 7e2ce5e4` (instrumentation)
- **Related issues:** #31 (buffer pool race, fixed), #32 (pool preallocation off-by-one)

## Summary

Investigate whether exploiting frame-to-frame temporal coherence with an
insertion-sort-from-previous-frame strategy can outperform the existing CPU
radix sort for Gaussian splat depth ordering.

## Conjecture

When the camera moves only slightly between frames, the previous frame's
sorted index buffer should be *nearly* sorted under the new view. Insertion
sort runs in O(n) on nearly-sorted data, which would beat the existing
two-pass radix sort. A move budget (4·n) caps the worst case and falls
back to radix when exceeded.

**Predicted outcome:** sub-millisecond adaptive sorts for typical small
frame-to-frame camera deltas; rare bail-outs to radix for large jumps
(scene loads, teleports).

## Method

### Implementation

- New `cpuAdaptiveSort` / `cpuAdaptiveSortMultiCloud` paths in
  `CPUSplatRadixSorter`. Each:
  1. Copies the previous frame's sorted permutation.
  2. Recomputes each entry's distance against the new camera.
  3. Runs insertion sort with a move budget of 4·n.
  4. On budget exhaustion, falls back to the existing radix sort.

- `AsyncSortManager` snapshots the previous `currentSortedIndices` and
  passes it through to the sorter.

### Instrumentation

- Per-frame log line reporting **total**, **adaptive**, and **radix**
  timings, with adaptive results annotated `OK` (move count) or
  `BAIL` (move count + index reached).
- `MSGS_ADAPTIVE_SORT` environment variable to select strategy:
  - `0` / `radix` — radix only; insertion path fully skipped.
  - `1` / `insert` — insertion only with unbounded budget; no radix
    fallback (output may be glitchy on bail).
  - `2` / `hybrid` — try insertion, fall back to radix on bail (default).

### Workload

- Splat cloud: demo butterfly, **149,148 splats**
- Motion: continuous interactive rotation (camera outside cloud)
- Hardware: Apple Silicon

## Results

### Mode 0 — radix only (baseline)

```
CPU splat sort: total=0.75ms adaptive=skip radix=0.75ms (149148 splats)
```

Steady state: **~0.7–0.9 ms per frame**.

### Mode 2 — hybrid (the conjecture as proposed)

```
CPU splat sort: total=2.10ms adaptive=0.45ms[BAIL 596593 moves @5004] radix=1.55ms (149148 splats)
```

- Adaptive **bails out every single frame** at index ~5,000–12,000 / 149,148
  (3–8% of the buffer) after exhausting the 4·n = 596,592 move budget.
- Radix then runs the full sort anyway.
- Steady state: **~1.3–1.7 ms per frame** — roughly **2× slower** than
  baseline due to the wasted adaptive attempt.

### Mode 1 — insert only (unbounded budget, no fallback)

```
CPU splat sort: total=  0.91ms adaptive=skip   radix=0.88ms          (radix init)
CPU splat sort: total= 86.51ms adaptive=86.51ms[OK    177,520,270 moves] radix=skip
CPU splat sort: total=785.50ms adaptive=785.50ms[OK 1,727,509,880 moves] radix=skip
CPU splat sort: total=956.66ms adaptive=956.66ms[OK 2,047,373,647 moves] radix=skip
```

- Insertion sort takes **86 ms → 957 ms** per frame.
- Move counts grow into the **billions** — ~13,700 moves per element on
  average.
- Time degrades frame-over-frame because each frame's "previous"
  permutation is itself the result of insertion-sorting against an older
  camera, with no radix to re-baseline. Staleness compounds.

### Comparison

| Mode      | Per-frame time | Notes                                  |
|-----------|----------------|----------------------------------------|
| 0 radix   | ~0.8 ms        | Baseline                               |
| 2 hybrid  | ~1.5 ms        | ~2× slower; adaptive bails every frame |
| 1 insert  | 86–957 ms      | ~100–1000× slower; degrades over time  |

## Analysis

The conjecture's premise — "small camera motion → nearly-sorted previous
permutation" — only holds when:

1. The splat count is small (so even O(n²) is cheap), **or**
2. Motion is genuinely sub-pixel **and** splats are spatially clustered such
   that local depth order is stable.

Neither holds for a 149k butterfly under interactive rotation. Splats are
distributed in 3D, so any rotation reshuffles depth ordering globally, not
locally. The previous permutation is essentially uncorrelated with the new
correct ordering: ~13,700 inversions per element confirms this.

### Did the buffer copy / distance recompute contribute meaningfully?

No. The prep work (copy previous permutation + recompute 149k distances)
is O(n) and costs well under 1 ms. For reference, the entire radix sort,
which *also* does the distance pass, runs in ~0.8 ms total.

Of the 86–957 ms per frame in mode 1, **>99% is the insertion sort itself
moving elements**. The buffer copy and distance recompute are in the noise.

### Would the camera *inside* the cloud change anything?

Probably not meaningfully. The inversion count between frames is dominated
by **how many splats sit at similar depths**, not by where the camera is.
If anything, inside-looking-out might be slightly worse: splats span a full
4π steradian, so any rotation moves more of them across the view axis.

The only configurations that would actually help adaptive sorting are
sub-pixel motion or splats strongly clustered in depth. Neither describes
interactive viewing.

*Caveat: this is reasoning, not measurement.*

### Would a smarter adaptive sort (e.g. Timsort) help?

No. Timsort's win is finding long monotonic *runs* in the input — but our
data has inversions spread globally, so runs would be tiny. You'd get
O(n log n) ≈ 2.5M ops vs radix's ~300k writes — still slower.

More fundamentally: any **comparison-based** sort is bounded by Ω(n log n).
Radix is O(n) because it exploits the fixed-width key (16-bit Float16
distance). On uncorrelated data at this size, radix wins by definition.

## Conclusion

**The conjecture is rejected.** Radix sort is faster for this workload by
roughly three orders of magnitude. The adaptive-from-previous strategy as
implemented cannot be made viable for 100k+ splats under interactive motion
by tuning the move budget — the fundamental assumption is wrong at this
scale.

## Recommendations

1. **Revert** the adaptive sort commit. It is a net loss in both default
   (hybrid) and insert-only modes for any realistic splat cloud.
2. If temporal coherence is worth pursuing in future, it would need a
   fundamentally different approach. Possible directions:
   - Seeded radix buckets using the previous frame's bucket assignments.
   - Per-tile sorting in the tile-based renderer, where spatial locality is
     preserved.
   - Insertion sort *within* radix buckets after a single radix pass.
3. **Keep the instrumentation.** The per-frame timing log line and the
   `MSGS_ADAPTIVE_SORT` env-var mode switch are useful for future sort
   experiments and worth retaining even if the adaptive path is removed.

## Side findings

- **Buffer pool preallocation off-by-one:** a single
  `Pool exhausted, allocating new object (id: 5)` warning fires on startup.
  Tracked as #32.
- The buffer-pool race fix from #31 (deferred release of `SplatIndices` for
  3 frames) appears to be working — no visual glitches in any test run.
