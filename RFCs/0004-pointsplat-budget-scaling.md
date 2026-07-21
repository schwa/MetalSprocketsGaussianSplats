# RFC 0004 — PointSplat over-budget proportional thinning

- **Status:** Implemented
- **Date:** 2026-07-21
- **Author:** jwight
- **References:**
  - RFC 0003 (Gaussian Point Splatting)
  - Rijsdijk et al., *Gaussian Point Splatting*, SIGGRAPH 2026, Sec. 3.2–3.3
  - Issue #69 (occlusion culling, deferred)

## Summary

When a PointSplat frame's point demand exceeds the per-frame budget T,
scale every Gaussian's point count by `T / demand` with stochastic
rounding, instead of truncating the prefix-sum tail. This is a deviation
from the paper, which truncates.

## Motivation

The paper's work distribution assigns splat threads via an exclusive
prefix sum over per-Gaussian point counts; threads past the budget T
simply don't exist, so the *tail of the Gaussian array* loses all its
points. Gaussian array order correlates with spatial position (Morton /
capture order), so truncation deletes contiguous regions of the scene
rather than degrading uniformly.

The paper never observes this ("never happened in our experiments")
because its hierarchical occlusion culling and per-Gaussian clamps keep
demand far below budget on real captures. We don't have occlusion culling
yet (#69), and synthetic scenes hit the failure immediately: an opaque
8M-splat sphere demands >1G points (the entire occluded interior and back
hemisphere still request full counts), blowing through a 314M budget and
visibly carving chunks out of one side. Zooming in makes it worse since
every splat's screen area grows.

## Method

The workload distributor becomes two-pass when over budget:

1. Prefix-sum the raw counts; store the total ("demand") in `totals[1]`.
2. If demand > T: a per-Gaussian kernel scales each count by
   `T / demand`, stochastically rounded so expectations are exact
   (`E[round(c·s)] = c·s`). No-op when under budget.
3. Prefix-sum again into `totals[0]`; scatter and max-scan proceed as
   before, and the splat stage dispatches indirectly from `totals[0]`.

Cost: one extra G-sized scan pass and one G-sized scale dispatch,
negligible next to the splat stage. `totals` grows to two words so both
the consumed count and the raw demand are visible to the CPU (the demo
overlay shows "Points used / demand" and highlights when thinning is
active).

## Bias

This is not free. The opacity correction (RFC 0003, paper Sec. 3.3)
derives each Gaussian's rate λ so the Poisson zero-probability equals
1 − α; splatting `s·λ` points instead lowers every Gaussian's effective
opacity to `1 − (1−α(q))^s` — an over-budget converged frame is slightly
too transparent, uniformly. Truncation is also biased, but locally
catastrophic (whole regions missing) rather than globally gentle. We
prefer the gentle failure:

| | under budget | over budget |
|---|---|---|
| Truncation (paper) | exact | regions missing, order-dependent |
| Scaling (this RFC) | exact (scale = 1) | uniform noise + slight transparency |

## Relation to occlusion culling (#69)

Scaling is a backstop, not a fix. The correct way to bring demand under
budget is to stop generating points for occluded Gaussians (the paper's
two-phase hierarchical depth culling). Once #69 lands, the scale factor
should be 1 in virtually every frame and this path goes dormant —
matching the regime the paper operates in.

## Alternatives considered

- **Per-frame random permutation of Gaussian order** — decorrelates the
  truncated tail from spatial position, turning missing regions into
  uniform dropout. Destroys the sorted-index cache coherence the
  distributor exists to provide.
- **Raise the budget** — demand is unbounded (grows with zoom); any fixed
  budget can be exceeded, and budget scales the index buffer and splat
  cost.
- **Clamp per-Gaussian counts harder** — already done (half-framebuffer
  clamp); can't help when *many* Gaussians are large.
