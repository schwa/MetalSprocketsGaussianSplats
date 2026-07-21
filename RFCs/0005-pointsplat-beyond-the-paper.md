# RFC 0005 — PointSplat beyond the paper: variance, budget, and bias improvements

- **Status:** Draft
- **Date:** 2026-07-21
- **Author:** jwight
- **References:**
  - RFC 0003 (Gaussian Point Splatting — base implementation)
  - RFC 0004 (over-budget proportional thinning — implemented)
  - Rijsdijk, Peters, Weinmann, Marroquim, *Gaussian Point Splatting*,
    ACM TOG 45(4), SIGGRAPH 2026, doi:10.1145/3811272
  - Issue #69 (occlusion culling, deferred)

## Summary

A grab bag of improvements to the Gaussian Point Splatting method that go
*beyond* the paper, derived from the paper's own stated limitations
(Sec. 4.3) and from what we learned implementing it (RFC 0003) and
deviating from it (RFC 0004). Each proposal is independently adoptable;
they are ordered by expected impact. This RFC is a menu, not a plan —
individual items should graduate to their own RFC or issue before
implementation.

The proposals:

1. **Intra-thread stratified sampling** — remove most of the collision
   correction instead of paying for it.
2. **Importance-driven budget allocation** — generalize RFC 0004's
   thinning from uniform to visibility/variance-weighted.
3. **Point-size LoD under budget pressure** — trade resolution, not
   opacity or coverage, when over budget.
4. **Temporal point reuse (reservoir-style)** — recycle last frame's
   surviving points instead of resampling everything.
5. **Exact sub-pixel splatting** — fix the paper's aliasing bias where
   it actually occurs.
6. **Differentiable variant** — train scenes against the point-splat
   image formation (research-scale; recorded for completeness).
7. Smaller items: depth packing, color packing.

## Background: where the paper leaves gains on the table

The paper's design commits fully to *independent* sampling: every point
of every Gaussian is drawn independently, which is what makes the method
embarrassingly parallel. Everything else follows from that choice:

- Independent points from one Gaussian collide on the same pixel, so the
  effective opacity drops. The paper compensates *exactly* — the
  dilogarithm-corrected density of Sec. 3.3/3.4 — at a cost of up to
  π²/6 − 1 ≈ 64.5% extra points, plus the Li₂/Li₂⁻¹ polynomial
  machinery.
- Budget allocation is uniform: point count ∝ screen area × opacity,
  regardless of whether the Gaussian is occluded, or whether the pixels
  it lands on are already converged. Binary occlusion culling (deferred
  here as #69) is the only visibility feedback.
- Every frame resamples every point from scratch; temporal reuse is a
  post-hoc accumulation/reprojection of *resolved colors*, with the
  usual ghosting.
- The per-pixel Poisson model assumes the density is constant across a
  subpixel footprint (`A·p(q)`, their Eq. 1). For sub-pixel Gaussians
  this is violated and is the admitted source of their aliasing bias
  vs 3DGS (their Fig. 6, Sec. 4.3).

Each proposal below relaxes exactly one of these commitments while
keeping the parts that matter (no sort, no binning, flat per-thread
workload, atomic-min resolve).

## 1. Intra-thread stratified sampling

**Observation:** independence is only *required* between threads.
Within a thread, the K points splatted for one Gaussian (RFC 0003 step 4;
paper Sec. 3.4's K-amortization) are sampled in a plain loop — they could
be stratified for free, with no synchronization.

The collision correction exists because independent samples from the
same Gaussian collide. If a thread's K samples are stratified — e.g.
jittered strata over the (u₀, u₁) unit square, or sampled without
replacement over subpixel-sized strata of the Gaussian's footprint —
intra-thread collisions drop toward zero. Two effects:

- **Less work:** the corrected point count converges toward the
  uncorrected `2π√|Σ|·α/A`, shaving up to ~39% of splatted points for
  high-opacity Gaussians (the paper's Fig. 4a in reverse).
- **Less noise:** stratification is a classic variance reduction; the
  same converged image at lower SPP.

Collisions *between* threads of the same Gaussian remain (a Gaussian
big enough to span multiple threads still self-collides across them),
so the correction doesn't disappear entirely — it becomes a function of
K and the per-thread point count. The math: with n = λ/K threads each
placing K stratified points, the per-pixel zero-probability is no longer
`exp(−λAp)` but `(1 − Ap·K/·)ⁿ`-shaped; the corrected density needs
re-derivation with the Poisson replaced by a binomial-of-strata model.
This is the main open work item. A cheap intermediate: keep the paper's
correction but stratify u₁ (the angle) only — strictly reduces radial
clumping, needs no new math, measurable variance win.

**Interaction with the paper:** the paper explicitly notes K-rounding is
already "a deviation from our theory" with small visual impact (their
Fig. 7). We'd be deepening that deviation but in a direction that
*reduces* bias-per-point rather than adding it.

**Risks:** the re-derived correction may not have a closed form as clean
as the dilogarithm; if so, tabulate. Verify with the RFC 0003
convergence test (accumulated PointSplat vs Spark reference).

## 2. Importance-driven budget allocation

**Observation:** RFC 0004 already built the machinery — a per-Gaussian
count-scaling pass with stochastic rounding between the two prefix sums.
It currently applies one *uniform* scale `T / demand`. Nothing stops the
scale from being *per-Gaussian*.

Replace the uniform scale with a weight:

```
scale_g = clamp(w_g · T / Σ(w_i · n_i), 0, 1)
w_g     = visibility_g · convergence_g
```

- `visibility_g` ∈ [ε, 1]: estimated fraction of the Gaussian's
  footprint that passes the previous frame's hierarchical depth test.
  This is *soft* occlusion culling — instead of the paper's binary
  cull-or-render, mostly-hidden Gaussians get proportionally fewer
  points. The paper's own two-phase safety pass (#69's phase 2:
  re-render anything falsely culled against the phase-1 depth buffer)
  still guarantees no misses, so the estimate only needs to be roughly
  right.
- `convergence_g` ∈ [ε, 1]: down-weight Gaussians whose screen region
  has already converged under temporal accumulation (low running
  variance in the accumulation buffer). Puts samples where the noise is:
  disocclusions, moving-camera regions, high-frequency content.

**Bias:** same character as RFC 0004 — scaling counts by s lowers
effective opacity to `1 − (1−α(q))^s` — but now concentrated on
Gaussians that are occluded (invisible anyway) or converged (accumulated
history dominates). The visible-and-noisy Gaussians get scale ≈ 1. In
the under-budget case with visibility weighting only, this *is*
occlusion culling generalized: #69's binary mask is the special case
w ∈ {0, 1}.

**Cost:** the weight computation is one extra read per Gaussian in the
existing scale kernel (visibility from the depth-pyramid test that #69
needs anyway; variance from a per-tile statistic of the accumulation
buffer). No new passes.

**Dependencies:** #69 (hierarchical depth buffer) for `visibility_g`;
temporal accumulation variance tracking for `convergence_g`. Ship
visibility first; convergence is a follow-on.

## 3. Point-size LoD under budget pressure

**Observation:** RFC 0004's failure-mode table has two failure modes —
truncation loses *coverage* (regions missing), thinning loses *opacity*
(too transparent). There is a third axis to give up: *resolution*.

When a Gaussian's count is scaled by s < 1, optionally splat its points
at 2×2 (or 4×4) subpixel size instead of 1×1: the splat kernel writes a
small footprint of atomic-mins instead of one. Coverage and effective
opacity stay approximately correct while the point count drops by 4×
(16×); the error becomes local blur instead of transparency or holes.
This is a level-of-detail mechanism with none of the things the paper
avoids LoD for: no preprocessing, no hierarchy, no separate asset — the
"LoD selection" is a per-frame, per-Gaussian scalar that falls out of
the budget pass.

Sensible policy: engage only below a scale threshold (e.g. s < 0.5), and
prefer enlarging points of *low-frequency* Gaussians (large screen-space
√|Σ| relative to footprint) where blur is invisible. Tiny Gaussians
under budget pressure keep 1×1 points and take the thinning path.

**Interaction with 1 and 2:** orthogonal to both. The budget pass
(RFC 0004, extended by proposal 2) decides s per Gaussian; this proposal
decides how s is *spent* — fewer 1×1 points vs same-coverage bigger
points.

**Cost:** 4 (or 16) atomic-mins per point in LoD mode instead of 1, but
for 4× (16×) fewer points — net wash on atomics, big win on RNG,
sampling math, and Gaussian-attribute bandwidth. Needs the depth of the
enlarged point to be its center depth (no per-subpixel depth), which
introduces sub-point depth error — bounded by the point size, acceptable
at the scales where LoD engages.

**Risks:** the opacity correction assumes pixel-sized points; enlarged
points change the collision geometry. At the s-values where this
engages, exactness is already gone (RFC 0004's bias), so approximate
correction (correct λ for the coarser effective resolution: replace A by
4A in Eq. 2) should suffice. Verify visually against uniform thinning at
equal budget — the claim to test is "blur beats transparency."

## 4. Temporal point reuse (reservoir-style)

**Observation:** the points that *won* the depth test last frame are, by
construction, the important ones — they are the visible surface. The
paper throws them away every frame and resamples all ~10⁸ points from
scratch, then tries to recover temporal information *after* the resolve
by blending resolved colors (with the ghosting they admit to).

Instead, reuse at the *point* level, before the resolve:

```
1. REPROJECT  previous frame's resolved (depth, color) buffer through
              the motion transform into the current frame's 64-bit
              buffer as seed points (one point per previously-covered
              subpixel, depth-tested on write like any other point).
2. SPLAT      the current frame's fresh points on top, budget reduced
              by a reuse factor ρ (e.g. splat only (1−ρ)·T fresh
              points). Fresh points that are closer win via the same
              atomic-min — reprojection errors self-correct wherever
              fresh samples land.
3. VALIDATE   reject seed points whose reprojected depth disagrees with
              the current depth pyramid beyond a tolerance
              (disocclusion), leaving those pixels to fresh samples.
```

This is the ReSTIR intuition (temporal reservoir of visibility samples)
applied to the simplest possible reservoir: the depth buffer itself.
Unlike color-space reprojection it cannot ghost *colors across
surfaces* — a seed point carries its own depth and loses the atomic-min
to any closer fresh point.

**Bias:** seed points are survivors of last frame's min, so they
oversample the front surface relative to the Poisson model —
equivalently, effective opacity of front Gaussians increases with ρ.
For static cameras this is exactly what temporal accumulation converges
to anyway; for moving cameras, choose ρ modestly (0.5–0.75) and let
validation plus fresh sampling wash the error. This proposal trades
principled convergence for per-frame variance — appropriate for the
interactive path, not the offline/CLI ground-truth path (keep ρ = 0
there).

**Cost:** one fullscreen reproject pass (cheap, no atomic-contention
hotspots — writes are one per subpixel) versus splatting ρ·T fresh
points (tens of millions). Expected large net win at equal quality.

**Relation to the paper:** strictly subsumes their static-camera
accumulation (ρ→1, no motion) and addresses their admitted reprojection
ghosting by moving reuse from resolved colors to depth-tested points.

## 5. Exact sub-pixel splatting

**Observation:** the paper's only quality gap vs 3DGS is aliasing
differences (their Figs. 6, 12), caused by the `A·p(q)` constant-density
approximation breaking for Gaussians at or below pixel scale
(Sec. 4.3). Those same Gaussians receive ≤ ~1 point anyway — so the
fix is cheap precisely where it's needed.

For Gaussians whose screen-space extent (say 3σ_max) falls below a
subpixel threshold: skip the corrected-density sampling entirely.
Integrate the opacity over the (few) covered subpixel footprints
analytically (2D Gaussian integral over a box — separable erf terms in
the Cholesky frame, or a small LUT), and for each covered subpixel do a
single Bernoulli trial with the *exact* integrated probability, splatting
one point at the subpixel center on success. No collision correction
needed — at most one point per subpixel per Gaussian by construction.

This removes the paper's stated bias at its source rather than hiding it
with supersampling, and as a bonus the tiny-Gaussian path needs no
Li₂ evaluation, no CDF inversion, and no Poisson draw — cheaper per
Gaussian than the general path. Large scenes at distance (most Gaussians
sub-pixel — the paper's Fig. 9/10 regime) would take this path for the
bulk of the cloud.

**Risks:** two code paths in the preprocess/splat kernels (divergence —
mitigated by the Morton/order coherence the distributor already
provides); the box-integral must match the general path at the threshold
to avoid a visible seam (verify with a scale sweep across the
threshold).

## 6. Differentiable variant (research-scale, recorded for completeness)

The paper's biggest admitted limitation: no differentiable rendering, so
scenes must be trained with 3DGS, and the renderer then faithfully
reproduces 3DGS idiosyncrasies (pixel-center aliasing, popping) rather
than its own better-behaved image formation (box prefiltering, potential
3D sampling with no popping).

The visibility function here is a discrete argmin over stochastic
points — the same structure differentiable stochastic-transparency and
recent stochastic-3DGS training work handles with score-function or
smoothed-visibility estimators. A trainable point-splat renderer would
let scenes be optimized *for* this image formation, eliminating the
aliasing mismatch (proposal 5 becomes moot for such scenes) and
unlocking the paper's own "sample in 3D, kill popping" future-work
suggestion.

Out of scope for this repo in any near term (we render existing assets;
we don't train). Recorded so the trade is visible: proposals 1–5 make
rendering *of 3DGS-trained scenes* better; this one changes what a
"scene" is.

## 7. Smaller items

- **Depth packing:** the paper's 28-bit fixed-point view-space depth
  between near/far wastes precision at range and forces a far plane.
  For our reversed-infinite-Z camera paths (RFC 0003 open question 2),
  pack a monotonic transform of 1/z instead — same 28 bits, precision
  where the geometry is, no far-plane tuning. Any monotonic map works
  with atomic-min; this is free.
- **Color packing:** 3×12-bit sRGB over [0, 16) gives 1/256 steps —
  visible banding risk in dark accumulated regions. Consider a shared
  4-bit exponent + 3×10⁺-bit mantissas (RGB9E5-style) in the same 36
  bits, or drop the HDR range to [0, 4) when a scene's SH maxima allow
  (scene-level decision at load time). Only matters once noise is low
  enough for banding to show — i.e., after proposals 1/2/4 land.

## Suggested order

| Proposal | Effort | Wins | Depends on |
|---|---|---|---|
| 2a. visibility-weighted budget | S | perf at scale | #69 depth pyramid |
| 1 (angle-stratification only) | S | variance, free | — |
| 5. sub-pixel exact path | M | bias, perf at distance | — |
| 4. temporal point reuse | M | noise/perf, interactive | reprojection xform |
| 3. point-size LoD | M | graceful over-budget | RFC 0004 (done) |
| 1 (full stratified re-derivation) | L | points −~40% | math |
| 2b. convergence weighting | M | noise | variance tracking |
| 7. packings | S | polish | — |
| 6. differentiable | XL | out of scope | — |

Items graduating from this menu get their own RFC (for design-heavy
ones: 1-full, 3, 4) or issue (2a, 5, 7).

## Verification (common to all)

- The RFC 0003 convergence test remains the gate: accumulated PointSplat
  vs the Spark reference, PSNR tracked per proposal, no regression
  beyond each proposal's stated bias budget.
- Equal-time comparisons, not equal-SPP: every proposal above trades
  some exactness for samples-per-ms, so the honest metric is quality at
  fixed frame time on the picker's A/B path.
- Over-budget behavior (proposals 2, 3) tested on the RFC 0004 synthetic
  opaque-sphere scene where demand > 3× budget.
