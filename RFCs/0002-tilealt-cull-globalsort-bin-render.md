# RFC 0002 — TileAlt: Cull → Global Sort → Ordered Bin → Tile Render

- **Status:** Draft
- **Date:** 2026-07-20
- **Author:** jwight
- **Related issues:** #58 (tile perf), #59 (tile blending washed out), #61 (per-tile sort is single-threaded), #62 (unified front-end)

## Summary

A new tile-based splat renderer ("TileAlt") built as a sibling of the existing
experimental tile renderer (which stays untouched). It reuses the GPU pipeline's
cull + radix sort front-end (`SplatGPUSort`), then bins the *already
depth-sorted* survivors into tiles in a way that preserves order, so the
per-tile lists arrive sorted and the serial per-tile sort (#61) disappears
entirely. Rendering is the existing per-pixel imageblock walk, unchanged in
principle.

## Motivation

- Overdraw in real splat scenes is consistently extreme (empirical, all test
  scenes). Per-pixel front-to-back accumulation with early termination is the
  structural cure; the quad/blend path pays for every overlapping splat through
  the ROPs.
- The current tile renderer loses everywhere because of its sort: one thread
  per tile running a serial 4-pass radix (8 full walks of the tile list on a
  single thread, 256-entry private histogram). Dense tiles serialize for
  milliseconds.
- We already own a cooperative, culling, stable GPU radix sort
  (`SplatGPUSort`, ported for the GPU quad pipeline). TileAlt is mostly a
  recomposition of existing passes.

## Architecture

Per frame, one command buffer:

```
1. CULL + DEPTH SORT   (existing SplatGPUSort, unchanged)
   frustum cull, stable compact, 2× 8-bit radix over 16-bit half depth key
   → survivor records {depthKey|_, splatID}, survivor count in sortArgs

2. ORDERED EXPANSION ("bin without breaking order")
   a. per sorted survivor: project, compute covered-tile count  → counts[i]
   b. exclusive prefix sum over counts                          → expandBase[i], total M
   c. per sorted survivor: write its entries
      {tileID, splatID} at expandBase[i]..< expandBase[i]+counts[i]
   Deterministic offsets — no atomics — so entries inherit the global depth
   order. (This is the original 3DGS CUDA scheme, minus the combined key.)

3. STABLE TILE PARTITION
   2× 8-bit radix passes over the 16-bit tileID (reusing the existing
   histogram / scanOffsets / scanDigitBase / scatter kernels with shift 0, 8).
   Stability preserves depth order within each tile. The sort's per-digit
   totals double as the per-tile counts → prefix sum → tileOffsets.

4. TILE RENDER          (existing imageblock fragment walk, unchanged)
   per-pixel front-to-back accumulation with early termination over the
   tile's pre-sorted range; imageblock → framebuffer composite.
```

### Why sort depth first, then partition by tile?

Sorting by combined key `(tileID << 16) | depthKey` needs 4 radix passes over
M expanded entries. Sorting depth first needs only 2 passes over N splats
(N ≪ M), and the tile partition needs 2 passes over M. Since M ≈ 4–8× N,
moving half the passes from M-sized to N-sized data roughly halves sort
bandwidth versus the combined-key formulation.

A 16-bit tileID caps the grid at 65,536 tiles (e.g. 4096×2304 px at 16-px
tiles). Larger drawables need a third partition pass or bigger tiles; assert
for now.

## Dependencies / open needs

- **GPU-driven dispatch sizing.** Steps 2c and 3 are sized by the survivor
  count and M, which only the GPU knows. Options, in preference order:
  1. Indirect dispatch (`dispatchThreadgroups(indirectBuffer:)`) —
     **not currently exposed by MetalSprockets `ComputeDispatch`; file a
     MetalSprockets ticket**.
  2. Over-dispatch to capacity with early-out guards (works today; wastes
     threadgroups, and the radix scan kernels do per-tile work proportional
     to the dispatch-time tile count, so this is measurably worse).
  3. Previous-frame readback as a size estimate with margin (lag/first-frame
     hazards).
- Prefix sum over per-splat counts (step 2b): the existing
  `TilePrefixSum` kernel or a port of the block-scan from `SplatGPUSort`.

## Performance estimate

Scene basis: Butterfly, N = 149k splats, ~2K drawable, 16-px tiles
(~9.2k tiles), assume avg 6 tiles/splat → M ≈ 0.9M entries, 8-byte entries.

| Stage | Traffic (approx) | Est. time (M-series, ~200 GB/s effective) |
|---|---|---|
| Cull + depth sort (2 passes, N) | ~15 MB | ~0.1 ms |
| Expansion (project ×2, write M) | ~25 MB | ~0.15 ms |
| Tile partition (2 passes, M) | ~60 MB | ~0.3–0.5 ms |
| tileOffsets prefix sum | negligible | <0.05 ms |
| **Front-end total** | ~100 MB | **~0.5–0.8 ms** |

Current per-tile serial sort for comparison: a dense tile with ~5k entries
does 8 serial walks ≈ 40k dependent memory ops on one thread; with many dense
tiles the pass runs multi-millisecond and scales with the *worst* tile, not
the average. Expect roughly an order of magnitude on the sort stage alone.

Render stage is unchanged, so end-to-end wins are capped by the render's
per-pixel loop (which still re-projects every splat per pixel — see "Future"
below). Predicted end-to-end: tile path drops from "worst renderer in the
picker" to within striking distance of the GPU quad path on the butterfly,
and ahead of it in high-overdraw interior scenes where early termination bites.

## Verification plan

- GPU frame capture: confirm sort/partition stage times vs the table above.
- Correctness: per-tile ranges strictly depth-ascending (debug compute pass
  asserting monotonic keys); visual parity with Spark renderer (also a check
  on #59 — if TileAlt renders correctly, the old tile renderer's wash-out is
  in its sort order or blend math, not the architecture).
- A/B in the demo picker: Tile (old) vs TileAlt vs Gpu on butterfly + an
  interior/high-overdraw scene.

## Future (out of scope)

- Cache projected 2D covariance/ellipse per splat during expansion so the
  render loop stops re-deriving it per pixel (the other half of #58).
- Third back-end: rasterized quads + imageblock read-modify-write
  (programmable blending) — hardware rasterization with on-chip compositing,
  no per-pixel full-list walk (noted in #62 discussion).
- Stereo/visionOS (#56) applies here as much as to the quad path.
