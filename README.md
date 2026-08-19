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
  all on the GPU, feeding the quad renderer through an indirect draw.
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

- **Apple Silicon:** built for the tile-based deferred GPU. Keeps each tile in
  on-chip tile memory and composites in an imageblock, avoiding device-memory
  round trips.
- **Technique:** bins splats per tile, sorts each tile by depth, and composites
  front-to-back in an imageblock fragment shader.
- **Performance:** work in progress. Tiles with heavy overlap dominate the frame
  time from poor load balancing.

### Stochastic (`.stochastic`) — experimental

- **Technique:** sort-free. Each quad passes a probabilistic alpha test with
  blue-noise sampling, giving correct expected transparency with no depth order.
- **Performance:** no sort cost, but fragment cost grows with overdraw. Noisy at
  1 sample per pixel; built for temporal accumulation.

### PointSplat (`.point`) — experimental

An implementation of [*Gaussian Point Splatting*](https://momentsingraphics.de/Siggraph2026.html)
(Rijsdijk et al., SIGGRAPH 2026). See also the authors'
[reference implementation](https://github.com/JorisAR/gaussian-point-splatting).

- **Technique:** sort-free and rasterization-free. Each Gaussian emits
  pixel-sized points into a 64-bit depth-and-color buffer with `atomic_min`, so
  the closest point wins. Needs 64-bit atomics: Apple9 (A17/M3) or later, or
  Mac2.
- **Performance:** cost scales with points splatted, not sort size or overdraw,
  so frame times stay flat into the millions of splats. Noisy per frame;
  converges within tens of frames.

## Benchmarks

PointSplat stays nearly flat as the splat count grows. Spark and GPU-sort grow
with the splat count. See the full tables, charts, and per-pass timings in
[Documentation/Benchmark.md](Documentation/Benchmark.md).

## Usage

There are three ways to drive the framework, from simplest to lowest-level.

### Simple: SplatView

`SplatView` is a SwiftUI view that renders a splat cloud. It owns the sort
manager and the render loop. Pick a renderer with `.splatRenderer(_:)`.

```swift
SplatView(splatCloud: cloud, cameraMatrix: cameraMatrix)
    .splatRenderer(.spark)   // or .gpu, .tile, .stochastic, .point
```

### MetalSprockets pipeline (interactive)

To own the render loop, drive a render pipeline directly as a MetalSprockets
element. Rendering needs two steps: sorting and rendering. The sort manager
runs on a background thread. It produces sorted indices that you pass to the
pipeline.

```swift
@State private var sortedIndices: SplatIndices?

var body: some View {
    RenderView { _, drawableSize in
        if let sortedIndices {
            try RenderPass {
                try SparkSplatRenderPipeline(
                    splatCloud: cloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: .identity,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(drawableSize),
                    sortedIndices: sortedIndices
                )
            }
        }
    }
    .task {
        for await indices in sortManager.sortedIndicesStream {
            sortedIndices = indices
        }
    }
    .onChange(of: cameraMatrix, initial: true) {
        sortManager.requestSort(SortParameters(camera: cameraMatrix, model: .identity))
    }
}
```

### Offline renderer

```swift
let sortManager = try AsyncSortManager(device: device, splatCloud: cloud, capacity: cloud.count)
let sortedIndices = try sortManager.sortNowSync(SortParameters(camera: cameraMatrix, model: .identity))

let renderPass = try RenderPass {
    try SparkSplatRenderPipeline(
        splatCloud: cloud,
        projectionMatrix: projectionMatrix,
        modelMatrix: .identity,
        cameraMatrix: cameraMatrix,
        drawableSize: drawableSize,
        sortedIndices: sortedIndices
    )
}
```

The render pipelines are pure rendering elements. They do not manage the
sorting or the async state. The caller owns the `AsyncSortManager`. The caller
subscribes to its `sortedIndicesStream`, requests a sort when the camera moves,
and passes the results in.

## Environment Variables

- `MSGS_SORT_LOG` — set this to `1`, `true`, `yes`, or `on`. Then the CPU
  splat sorter emits a per-frame info-level log line with the sort duration and
  the splat count. The default is off, because the logs are noisy at frame
  rate. Slow-sort warnings (more than 16 ms) are always emitted, whatever this
  setting is.

  The logs go to the unified logging system under the subsystem
  `MetalSprocketsGaussianSplats`. Read them in a terminal with:

  ```sh
  log stream --level info --predicate 'subsystem == "MetalSprocketsGaussianSplats"'
  ```

## License

MIT License. See LICENSE file for details.

## Acknowledgments

The two renderers in this project are based on work by the projects below. A
big thanks to their authors for releasing their code under permissive licenses.

• [antimatter15](https://github.com/antimatter15/splat) (MIT license) — for the original GS renderer and the reference that almost everyone starts from.
• [sparkjs](http://sparkjs.dev) (MIT License) — for the clean implementation that makes porting sane.
