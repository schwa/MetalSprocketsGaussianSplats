# MetalSprockets Gaussian Splats

Gaussian Splat rendering built on [MetalSprockets](https://metalsprockets/com) ([Github](https://github.com/schwa/MetalSprockets)).

Read the [announcement post](https://blog.schwa.io/posts/metalsprockets-gaussian-splats/) for background.

This repository has a standalone renderer and a Swift framework. You can add the framework to your own project.

There is also a CLI target for offline rendering. See the Justfile for how to use it.

The Wikipedia article is a good summary of the technique: [Wikipedia](https://en.wikipedia.org/wiki/Gaussian_splatting)

## Requirements

- Any current iOS device or Apple Silicon Mac.
- This project needs macOS 26/iOS 26 now. You can backport it with little effort.
- **Simulators are not supported.** The Spark pipeline uses nested Metal
  argument buffers. Simulator Metal rejects these buffers. As a result, splat
  rendering shows nothing in the iOS/visionOS simulators. Run on a real
  device, or run natively on macOS.

## File Formats

The framework loads these Gaussian splat formats:

- **PLY** (`.ply`) — the common point-cloud format that most tools export. PLY
  files are uncompressed, so they are large.
- **SPLAT** (`.splat`) — the uncompressed Antimatter15 Gaussian splat format.
- **SPZ** (`.spz`) — the compressed [Niantic format](https://github.com/nianticlabs/spz).
  Supports versions 2, 3, and 4. SH4 is not supported for version 4. The
  decoder is GPU-accelerated.
- **SOG** (`.sog`) — the [Spatially Ordered Gaussians format](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/sog/)
  from PlayCanvas. The decoder is GPU-accelerated. SOG usually produces the
  smallest files.

## Renderers

The framework has five renderers that you can exchange. Pick one with the
`.splatRenderer(_:)` modifier on `SplatView`, or in the demo app's picker. See
[Usage](#usage) for the three ways to drive them. Each renderer is also a
MetalSprockets element that you can use directly. See [Usage](#usage) for the
per-frame construction.

### Spark (GPU Sort) (`.gpu`)

The preferred renderer. Spark's shading with a GPU sort front-end.

- **Technique:** frustum cull, stable compaction, and an 8-bit LSD radix sort,
  all on the GPU. It feeds the quad renderer through an indirect draw.
- **Performance:** wins under constant camera motion or heavy culling. A fixed
  per-frame sort cost makes Spark cheaper for small static scenes.

### Spark (`.spark`)

Sorted splatting with a CPU radix sort. Ported from [sparkjs](http://sparkjs.dev).

- **Technique:** a CPU radix sort orders splats back-to-front each frame. Each
  splat draws as an alpha-blended quad sized by its 2D covariance. Supports
  spherical harmonics and multiple clouds.
- **Performance:** best quality-per-watt for small and medium scenes. The async
  sort can pop during fast motion, and sort time grows with splat count.
- **Debug vs Release:** the CPU sort is much slower in Debug. Benchmark in
  Release. A slow sort (more than 16 ms) logs a warning.

### Tile (`.tile`) — experimental

- **Apple Silicon:** built for the tile-based deferred GPU. It keeps each tile
  in on-chip tile memory and composites in an imageblock. This avoids
  device-memory round trips.
- **Technique:** bins splats per tile, sorts each tile by depth, and composites
  front-to-back in an imageblock fragment shader.
- **Performance:** work in progress. Tiles with heavy overlap dominate the frame
  time from poor load balancing.

### Stochastic (`.stochastic`) — experimental

- **Technique:** sort-free. Each quad passes a probabilistic alpha test with
  blue-noise sampling. This gives correct expected transparency with no depth
  order.
- **Performance:** no sort cost, but fragment cost grows with overdraw. The
  result is noisy at 1 sample per pixel. Built for temporal accumulation.

### PointSplat (`.point`) — experimental

An implementation of [*Gaussian Point Splatting*](https://momentsingraphics.de/Siggraph2026.html)
(Rijsdijk et al., SIGGRAPH 2026). See also the authors'
[reference implementation](https://github.com/JorisAR/gaussian-point-splatting).

- **Technique:** sort-free and rasterization-free. Each Gaussian emits
  pixel-sized points into a 64-bit depth-and-color buffer with `atomic_min`, so
  the closest point wins. Needs 64-bit atomics: Apple9 (A17/M3) or later, or
  Mac2.
- **Performance:** cost scales with points splatted, not sort size or overdraw,
  so frame times stay flat into the millions of splats. Each frame is noisy.
  The image converges within tens of frames.

## Benchmarks

PointSplat stays nearly flat as the splat count grows. Spark and GPU-sort grow
with the splat count. See the full tables, charts, and per-pass timings in
[Documentation/Benchmark.md](Documentation/Benchmark.md).

## Usage

There are two ways to drive the framework, from simplest to lowest-level.

### Simple: SplatView

`SplatView` is a SwiftUI view that renders a splat cloud. It sorts, culls, and
renders on the GPU each frame. Pick a renderer with `.splatRenderer(_:)`.

```swift
SplatView(splatCloud: cloud, cameraMatrix: cameraMatrix)
    .splatRenderer(.sparkGPU)   // or .tileBased, .stochastic, .pointSplat
```

### MetalSprockets pipeline

To own the render loop, drive `GPUSortedSplatRenderPipeline` directly as a
MetalSprockets element. It sorts, frustum-culls, and renders in one GPU
workload, so there is no CPU sort and no async state to manage.

```swift
@State private var sortResources: GPUSortResources   // create once

var body: some View {
    RenderView { _, drawableSize in
        try GPUSortedSplatRenderPipeline(
            splatCloud: cloud,
            projectionMatrix: projectionMatrix,
            modelMatrix: .identity,
            cameraMatrix: cameraMatrix,
            drawableSize: SIMD2<Float>(drawableSize),
            resources: sortResources
        )
    }
}
```

`GPUSortedSplatRenderPipeline` encodes a `GPUSplatSortComputePass` into a slot
of the shared `GPUSortResources` and then renders through
`SparkSplatRenderPipeline` with an indirect draw. To compose the render with
other passes, encode the sort compute pass yourself and hand the resulting
`SplatIndices` to `SparkSplatRenderPipeline`.

### Offline rendering

`OffscreenSplatRenderer` renders single frames to an image with any renderer:

```swift
let renderer = try OffscreenSplatRenderer(
    renderer: .spark,
    splatCloud: cloud,
    projection: PerspectiveProjection(),
    cameraMatrix: cameraMatrix,
    configuration: .init(width: 1_024, height: 768)
)
try renderer.renderFrame()
let image = try renderer.makeImage()
```

## License

MIT License. See LICENSE file for details.

## Acknowledgments

The two renderers in this project are based on work by the projects below. A
big thanks to their authors for releasing their code under permissive licenses.

• [antimatter15](https://github.com/antimatter15/splat) (MIT license)
• [sparkjs](http://sparkjs.dev) (MIT License)
