# PointSplat Implementation Plan (RFC 0003)

Repo: `~/Shared/Projects/Current/MetalSprocketsGaussianSplats`
Reference code: `~/Projects/Vendor/gaussian-point-splatting/src/core/`
RFC: `RFCs/0003-gaussian-point-splatting.md`

Build/test each phase with `xcb` before moving on.

## Phase 0 — Feasibility spikes (no renderer yet)

1. **64-bit atomic probe.** Tiny compute kernel doing
   `atomic_min_explicit` on `atomic_ulong`. Verify it compiles (MSL 3.1)
   and runs on target hardware; gate with `device.supportsFamily(.apple9)`.
   This is the go/no-go for the whole RFC.
2. **Math port + CPU tests.** Port to a small Swift/Metal-shared header:
   - `dilog` / `inv_dilog` FMA chains (verbatim from `random.cuh`)
   - pcg2d, hash32, makeSeed, stochastic_round
   - Giles Q̃_N3 Poisson sampler (`poisson.cuh`)
   - `correctedBoxMuller`
   Unit-test against reference values (Swift Testing): Li₂(1) = π²/6,
   fit error < 1e-4, Poisson mean/variance ≈ λ, corrected sampler
   histogram vs Eq. 2 density.

## Phase 1 — Work distribution

3. **Scan infrastructure.** Reuse `TilePrefixSum` skeleton:
   - exclusive `+`-scan over per-Gaussian point counts
   - scatter (`g[t_g] := g` where `n_g ≠ 0`)
   - inclusive `max`-scan
   Unit-test on CPU-verifiable fixtures (incl. Fig. 2 example: counts
   [2,1,0,4,0,1] → indices [0,0,1,3,3,3,3,5]).
4. **Indirect dispatch.** Total point count M is GPU-side; use the RFC 0002
   workaround ladder (readback for v0 is fine, indirect dispatch later).

## Phase 2 — Renderer skeleton

5. **`PointSplatRenderPipeline`** (sibling of `StochasticSplatRenderPipeline`):
   - 64-bit framebuffer (`W·H` `ulong`, 1×1 supersampling, numPasses = 1)
   - clear pass (background color packed as `0xFFFFFFF << 36 | color36`)
   - preprocess kernel: frustum cull, near cull (−z ≤ 0.2), cov2d + 0.3·I
     floor, importance = 2π√|Σ|·Li₂(α), Poisson count, per-Gaussian clamp
     min(n, W·H/2), write counts + visibility mask
   - splat kernel: K = 1; recompute cov2d/Cholesky per thread (no splat
     record buffer, matching reference); corrected Box–Muller sample;
     reject α·weight < 1/255 and out-of-bounds; early depth test then
     `atomic_min`
   - resolve pass: unpack, average passes/subpixels (trivial at 1×1),
     write float target
   - depth packing: 28-bit fixed-point view depth between near/far.
     **Decide reversed-Z reconciliation here** (RFC open question 2) —
     pick explicit near/far for this pipeline.
6. **RenderConfig knobs:** `maxPointsPerFrame` (default low, e.g. 16M),
   seed, near/far.

## Phase 3 — Integration & convergence

7. Wire into demo picker alongside Spark/Gpu/Stochastic/Tile.
8. Hook up `TemporalAccumulationShader` (mandatory — 1 SPP is PSNR ~17).
9. **Convergence test:** static camera, accumulate N frames, PSNR vs Spark
   output. Determinism test: fixed seed → identical image.

## Phase 4 — Quality & performance

10. Supersampling 2×2 + K = 4 (buffer slices per reference impl;
    covariance floor scales as 0.3·s²).
11. simdgroup dedupe before atomicMin (reference only has the early
    depth test; measure whether dedupe pays off on Apple GPUs).
12. GPU capture: occupancy of splat dispatch, atomic throughput.
    Scaling curve A/B vs sorted pipelines on small + multi-million-splat
    scenes.

## Deferred (per RFC)

- Occlusion/hierarchical culling (two-phase scheme)
- Temporal reprojection
- Pre-Apple9 32-bit fallback
- Morton preprocessing, budget-overflow handling beyond debug assert

## Key risks

- 64-bit atomic support/perf on Apple GPUs (Phase 0 answers this)
- Reversed-infinite-Z vs fixed-point near/far depth packing
- Noise at 1 SPP without accumulation may look unacceptable in demo
