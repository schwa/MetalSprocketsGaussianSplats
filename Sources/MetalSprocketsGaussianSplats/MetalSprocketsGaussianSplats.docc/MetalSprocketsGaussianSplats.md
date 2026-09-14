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
    .splatRenderer(.sparkGPU)   // or .tileBased, .stochastic, .pointSplat
```

Each renderer is also usable directly as a MetalSprockets element for custom
render graphs. On visionOS, `SplatImmersiveContent` renders splat clouds in
an immersive space with per-eye vertex amplification.

### Renderers

The framework ships four interchangeable renderers, selected via
``SplatRenderer``:

- **Spark** (``GPUSortedSplatRenderPipeline``) — the default production
  renderer, ported from sparkjs. A GPU sort orders splats back-to-front and
  frustum-culls in the same workload as rendering; each splat rasterizes as an
  alpha-blended quad. Supports spherical harmonics and multiple clouds.
  ``SparkSplatRenderPipeline`` is the underlying render element; pass it
  pre-sorted indices to compose the render with other passes.
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

- ``SortParameters``
- ``SplatIndices``
- ``GPUSplatSortComputePass``
- ``GPUSortResources``

