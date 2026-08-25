# ``MetalSprocketsGaussianSplats``

Render Gaussian splats with Metal, using interchangeable renderers built on
MetalSprockets.

## Overview

MetalSprocketsGaussianSplats renders 3D Gaussian splat scenes loaded with the
`Splats` library. The easiest way in is ``SplatView``, a SwiftUI view that
renders one or more ``GPUSplatCloud``s and lets you switch rendering
algorithms with the ``SwiftUICore/View/splatRenderer(_:)`` modifier:

```swift
SplatView(splatCloud: cloud, cameraMatrix: cameraMatrix)
    .splatRenderer(.sparkCPU)   // or .sparkGPU, .tileBased, .stochastic, .pointSplat
```

Each renderer is also usable directly as a MetalSprockets element for custom
render graphs. On visionOS, `SplatImmersiveContent` renders splat clouds in
an immersive space with per-eye vertex amplification.

### Renderers

The framework ships five interchangeable renderers, selected via
``SplatRenderer``:

- **Spark** (``SparkSplatRenderPipeline``) — the default production renderer,
  ported from sparkjs. A CPU radix sort orders splats back-to-front; each
  splat rasterizes as an alpha-blended quad. Supports spherical harmonics and
  multiple clouds.
- **GPU-sorted** (``GPUSortedSplatRenderPipeline``) — Spark's shading with a
  GPU bitonic sort and frustum culling in the same workload as rendering.
- **Tile-based** (``TileBasedSplatPipeline``) — experimental; bins and sorts
  splats per screen tile and composites with an imageblock fragment shader.
- **Stochastic** (``StochasticSplatRenderPipeline``) — experimental;
  sort-free stochastic transparency, noisier but with no sort cost.
- **Point splat** (``PointSplatRenderPipeline``) — experimental; sort-free
  pixel-sized points via 64-bit atomics with temporal accumulation. Requires
  Apple9/Mac2 GPU families.

## Topics

### Getting Started

- ``SplatView``
- ``SplatRenderer``
- ``GPUSplatCloud``
- ``SortableSplatProtocol``

### Spark Renderer

- ``SparkSplatRenderPipeline``
- ``GPUSortedSplatRenderPipeline``

### Tile-Based Renderer

- ``TileBasedSplatPipeline``
- ``TileBasedSplatPass``
- ``TileSplatRenderPass``

### Stochastic Renderer

- ``StochasticSplatRenderPipeline``

### Point Splat Renderer

- ``PointSplatRenderPipeline``
- ``PointSplatComputePass``
- ``PointSplatStatistics``

### Sorting

- ``SplatSorter``
- ``AsyncSortManager``
- ``SortEvent``
- ``SortParameters``
- ``SplatIndices``
- ``GPUSplatSortComputePass``
- ``GPUSortResources``

### Support

- ``SingleValueStream``
