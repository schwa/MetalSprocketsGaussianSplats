# RFC 0003 — Gaussian Point Splatting: sort-free stochastic point renderer

- **Status:** Draft
- **Date:** 2026-07-21
- **Author:** jwight
- **References:**
  - Paper page: <https://jorisar.nl/gaussian_point_splatting/>
  - Paper PDF: <https://jorisar.nl/gaussian_point_splatting/gaussian_point_splatting.pdf>
  - Reference implementation (CUDA/OpenGL): <https://github.com/JorisAR/gaussian-point-splatting>
  - Shadertoy demo: <https://www.shadertoy.com/view/WXdyWr>
  - Supplemental videos: [without reprojection](https://momentsingraphics.de/Media/Siggraph2026/rijsdijk2026_gps_2x2_k4_1spp.mp4), [with reprojection](https://momentsingraphics.de/Media/Siggraph2026/rijsdijk2026_gps_2x2_k4_1spp_reprojection.mp4)
  - Citation: Rijsdijk, Peters, Weinmann, Marroquim, *Gaussian Point Splatting*, ACM TOG 45(4), SIGGRAPH 2026, doi:10.1145/3811272

## Summary

A new renderer ("PointSplat") implementing the Gaussian Point Splatting method
from Rijsdijk et al. Instead of rasterizing sorted, alpha-blended quads, each
Gaussian emits N stochastically sampled *pixel-sized opaque points*; points are
splatted into a per-pixel `(depth, color)` buffer with a single 64-bit
`atomic_min`, and transparency is handled stochastically (each point survives
with probability derived from the Gaussian's opacity). With enough samples per
pixel this converges to the same image as the sorted pipelines — **with no
sort, no tile binning, and no blending** anywhere in the frame. (The point
splatting substrate is from Schütz et al. 2021, *Rendering Point Clouds with
Compute Shaders and Vertex Order Optimization*.)

This is a sibling of the existing renderers (Spark quad, GPU quad, Tile,
TileAlt per RFC 0002, and the current Stochastic quad renderer); nothing
existing changes.

## Motivation

- Every current pipeline in this repo pays for a depth sort (`SplatGPUSort` or
  the CPU sort manager) and/or tile machinery. Sorting is the scaling wall for
  large clouds and the source of most of our cross-renderer complexity
  (RFC 0001, RFC 0002, issues #58/#61/#62).
- The paper demonstrates 425M Gaussians interactive on an RTX 4070 Ti SUPER
  with **no** LOD, no approximation, no acceleration structure. Our target
  scenes (hundreds of k to tens of M) are small by comparison.
- Our existing `StochasticSplatRenderPipeline` already does stochastic
  transparency + temporal accumulation, but still rasterizes one *quad per
  Gaussian* — cost scales with screen-space area × overdraw. Point splatting
  makes cost scale with **points splatted** (bounded per frame, evenly
  distributed across threads) regardless of overdraw.
- The atomic-min "closest point wins" resolve means order independence: no
  sort correctness bugs (#59-class issues) by construction.

## Method (per the paper)

Per frame, per sample-per-pixel pass (SPP ≥ 1), one command buffer:

```
1. CULL       frustum + optional occlusion (screen AABB + min depth vs a
              hierarchical depth buffer from the previous frame) → 1 visibility
              bit per Gaussian, packed into 32-bit words.

2. COUNT      per visible Gaussian: Poisson-sample its point count n_g from an
              opacity-corrected density (the paper's Sec. 3.3: the naive
              density gives 1−e^{-α} effective opacity, so α=1 would render at
              63.2%; the correction uses a dilogarithm-based reweighting and a
              collision-compensation factor of up to π²/6 ≈ +64.5%). Counts are
              stochastically rounded to a multiple of K (K = points per
              thread, typically = the supersampling rate). → counts[g]

3. DISTRIBUTE exclusive prefix sum over counts → t_g, total M ≤ T (fixed
              per-frame budget). Then invert the mapping with a scatter +
              inclusive *max*-scan: zero-init g[0..T), scatter g[t_g] := g for
              n_g ≠ 0, max-scan → g[t] = the Gaussian thread t samples.
              Two scans + one scatter; output is sorted by Gaussian index,
              which keeps splat-stage reads cache-coherent.

4. SPLAT      thread t (splatting K points): sample radius r via inverse-CDF
              of the corrected radial density (needs polynomial fits of Li₂
              and Li₂⁻¹, max abs error ~7e-5), angle 2πu₁, Box–Muller-style
              q = Lo + μ in screen space. Reject outside the 3DGS truncation
              range; covariance gets the standard +0.3·I floor. Round q to a
              (supersampled) pixel, then:
                atomic_min(fb64[pixel], pack(depth, color))
              Opaque points → min over depth = correct front sample.

5. RESOLVE    average the S×S subpixels (box filter; the paper tried a
              Gaussian filter and rejected it as blurrier than 3DGS) into a
              float framebuffer; static-camera accumulation or reprojection
              on top (our TemporalAccumulationShader).
```

Key packing (paper's scheme, after Schütz et al.): high **28 bits** =
fixed-point view-space depth quantized between near/far planes; low **36
bits** = 3×12-bit sRGB with range [0, 16) at 1/256 steps (headroom above 1.0
matters — SH colors can exceed 1).

## Metal mapping

| Paper (CUDA) | Metal |
|---|---|
| 64-bit `atomicMin` on buffer | `atomic_min_explicit` on `atomic_ulong` — **requires MSL 3.1 + Apple9 family (A17/M3) or Mac2**. Gate with `device.supportsFamily(.apple9)`. |
| Thrust prefix sum + scatter + max-scan | reuse `TilePrefixSum` / `SplatGPUSort` block scan; max-scan is the same scan skeleton with `max` instead of `+` |
| Poisson sampling (Giles 2016 Q̃_N3) + Li₂ / Li₂⁻¹ polynomial fits | port coefficients from the reference implementation (`packages`-free CUDA source) |
| Persistent threads / grid-stride | plain dispatch sized to M via indirect dispatch (same MetalSprockets gap as RFC 0002 — `dispatchThreadgroups(indirectBuffer:)` not yet exposed; same workaround ladder applies) |
| OpenGL interop display | resolve compute pass → drawable, via MetalSprockets `ComputeDispatch` + blit |

Fallback for pre-Apple9 hardware (deferred, likely never): two-pass 32-bit
scheme — pass 1 `atomic_min` on depth only, pass 2 re-splat and write color
where depth matches. Doubles splat cost; out of scope for v1.

Existing pieces to reuse:

- `StochasticSplatRenderShader.metal`: PCG hash and sRGB/SH handling carry
  over. Note its per-fragment stochastic-transparency *test* is **not** the
  mechanism here — transparency emerges from the opacity-corrected point
  density; every splatted point is opaque.
- `TemporalAccumulationShader.metal`: unchanged for the no-reprojection mode;
  reprojection variant is a follow-up.
- `SplatGPUSort` culling front-end for the visibility pass (sort stages
  skipped — culling only).

## What we do NOT adopt (v1)

- Hierarchical / occlusion culling (`--disable-*` flags in the reference
  implementation) — our scenes don't need them yet; frustum cull only.
- Morton-order preprocessing.
- Supersampling factors > 1 (paper's default 2×2, with K = S²); start at
  native res, K = 1, and accept more noise — the paper's
  `--one-point-per-thread` mode is also the *more* correct one.
- The point-budget overflow path: if Σnᵢ exceeds T, tail Gaussians silently
  drop points (paper: "never happened in our experiments"); we just assert in
  debug.

## Performance expectations

Cost model: ~M points × (1 read of splat record + 1 atomic). Paper budget is
250M points/frame default on a 4070 Ti SUPER. For our butterfly scene
(149k splats, ~2K drawable) M lands in the low millions — well under an
M-series GPU's atomic throughput. The interesting comparison is the *scaling*
curve vs the sorted pipelines on multi-million-splat clouds, where sort
bandwidth currently dominates. Expect PointSplat noisy-but-flat frame times
where the sorted paths degrade.

Known cost: noise. 1 SPP without temporal accumulation is visibly stochastic
(see supplemental videos); with the existing temporal accumulation it should
converge in a handful of frames for static views.

## Verification plan

- **Convergence test:** accumulate PointSplat over many frames of a static
  camera; diff against the Spark renderer's output (PSNR target from paper:
  converges to deterministic result).
- **Determinism of the resolve:** fixed seed → identical image (atomic min is
  order-independent).
- GPU capture: confirm even occupancy across the splat dispatch (the paper's
  central claim) and atomic throughput.
- A/B in the demo picker vs Stochastic (quad) and Gpu renderers, small and
  large scenes; record the scaling curve.
- CLI offline path: render at high SPP for ground-truth comparisons.

## Open questions

1. **Apple9-only?** 64-bit atomics gate this to A17/M3+. Given the README
   already requires macOS 26/iOS 26, probably acceptable — confirm before
   building the fallback.
2. **Color/depth packing** — adopt the paper's 28-bit fixed-point depth +
   3×12-bit sRGB [0,16) as-is, or trade bits? 28-bit fixed-point depth needs
   sane near/far; our cameras currently use reversed-infinite-Z in some paths
   — reconcile.
3. **Li₂ fits** — lift coefficients from the reference repo vs re-fit; verify
   against the Shadertoy (which is a compact single-shader statement of the
   sampling math).
4. **Point count clamp / budget** — expose `maxPointsPerFrame` in
   `RenderConfig` (paper default 250e6; ours should default far lower).
5. Reprojection-based temporal reuse (paper's second video) — follow-up RFC
   or an extension of `TemporalAccumulationShader`?

## Future (out of scope)

- Temporal reprojection reuse.
- Hierarchical + occlusion culling for 100M+ scenes.
- Stereo/visionOS (#56) — note SPP cost doubles per eye; stochastic noise in
  stereo needs evaluation.
