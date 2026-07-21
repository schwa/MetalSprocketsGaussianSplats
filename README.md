# MetalSprockets Gaussian Splats

Gaussian Splat rendering built on [MetalSprockets](https://metalsprockets/com) ([Github](https://github.com/schwa/MetalSprockets)).

This repository includes both a standalone renderer and a Swift framework you can drop into your own project.

There’s also a CLI target for offline rendering. See the Justfile for how to drive it.

For anyone new the Wikipedia article is a great summary of the technique: [Wikipedia](https://en.wikipedia.org/wiki/Gaussian_splatting)

## Requirements

- Any current iOS device or Apple Silcon Mac.
- Currently requires macOS 26/iOS 26 - but can be backported with minimal effort.

## Renderers

The framework ships five interchangeable renderers, selectable in the demo
app's picker or via `SplatView`'s `.splatRenderer(_:)` modifier:

```swift
SplatView(splatCloud: cloud, cameraMatrix: cameraMatrix)
    .splatRenderer(.spark)   // or .gpu, .tile, .stochastic, .point
```

Each renderer is also usable directly as a MetalSprockets element; the
snippets below show the minimal per-frame construction (see `SplatView.swift`
for complete wiring).

### Spark (`.spark`)

The default production renderer, ported from [sparkjs](http://sparkjs.dev).

- **Technique:** classic sorted splatting. A CPU radix sort orders splats
  back-to-front each time the camera moves; each splat rasterizes as an
  alpha-blended quad sized by the projected 2D covariance. Supports
  spherical harmonics and multiple clouds.
- **Requirements:** any Apple Silicon Mac or current iOS device.
- **Performance:** best quality-per-watt for small/medium scenes (hundreds
  of k splats). The CPU sort runs async so frames never block on it, but
  sort latency shows as slight popping during fast camera motion, and sort
  time grows with splat count.
- **Debug vs Release:** the CPU radix sort is dramatically slower in Debug
  builds (unoptimized Swift), which shows up as sluggish resorting and
  pronounced popping while orbiting. Benchmark and demo in Release; slow
  sorts (>16 ms) log a warning either way.

```swift
try RenderPass {
    try SparkSplatRenderPipeline(
        splatCloud: cloud,
        projectionMatrix: projectionMatrix,
        modelMatrix: .identity,
        cameraMatrix: cameraMatrix,
        drawableSize: size,
        sortedIndices: sortedIndices   // from AsyncSortManager
    )
}
```

### GPU (`.gpu`)

Spark's shading with a GPU sort front-end.

- **Technique:** frustum cull + stable compaction + 8-bit LSD radix sort,
  all on the GPU timeline, feeding the same quad renderer via indirect
  draw. No CPU sort latency; culled splats never rasterize.
- **Requirements:** same as Spark.
- **Performance:** wins when the camera moves constantly (no stale sort)
  or when culling discards a large fraction of the cloud. Adds a fixed
  GPU cost per frame for the sort, so static views of small scenes are
  cheaper on Spark.

```swift
let resources = try GPUSortResources(device: device, capacity: cloud.count)  // once

try GPUSortedSplatRenderPipeline(
    splatCloud: cloud,
    projectionMatrix: projectionMatrix,
    modelMatrix: .identity,
    cameraMatrix: cameraMatrix,
    drawableSize: size,
    resources: resources
)
```

### Tile (`.tile`) — experimental

- **Technique:** screen is divided into tiles; splats are binned per tile,
  sorted per tile by depth, then composited front-to-back in an imageblock
  fragment shader (in the spirit of the original 3DGS rasterizer).
- **Requirements:** Apple Silicon (imageblocks / tile shaders).
- **Performance:** work in progress. Tiles with many overlapping splats
  dominate frame time (poor load balancing), which is the known weakness
  of tile-based splatting at scale.

```swift
try TileBasedSplatPass(
    splatCloud: cloud,
    projection: projection,
    drawableSize: size,
    cameraMatrix: cameraMatrix
)
```

### Stochastic (`.stochastic`) — experimental

- **Technique:** sort-free. Each splat rasterizes as an opaque quad and
  fragments pass a probabilistic alpha test (stochastic transparency),
  with blue-noise or hash sampling. Correct expected transparency without
  any depth ordering; noise averages out over frames.
- **Requirements:** same as Spark.
- **Performance:** no sort cost at all, but fragment cost scales with
  screen-space overdraw (every quad still rasterizes fully). Visibly noisy
  at 1 sample per pixel; intended for temporal accumulation.

```swift
try RenderPass {
    try StochasticSplatRenderPipeline(
        splatCloud: cloud,
        projectionMatrix: projectionMatrix,
        modelMatrix: .identity,
        cameraMatrix: cameraMatrix,
        drawableSize: size,
        frameTime: frameIndex
    )
    .depthCompare(function: .less, enabled: true)
}
```

### PointSplat (`.point`) — experimental

Implementation of *Gaussian Point Splatting* (Rijsdijk et al., SIGGRAPH
2026); see `RFCs/0003-gaussian-point-splatting.md`.

- **Technique:** sort-free and rasterization-free. Each Gaussian
  stochastically emits pixel-sized opaque points (count proportional to
  screen area × opacity, with an exact collision-compensating correction);
  points are splatted into a 64-bit depth+color buffer with `atomic_min`,
  so the closest point wins per pixel. 2×2 supersampling, box-filter
  resolve, and temporal accumulation converge it to the sorted result.
- **Requirements:** 64-bit atomics — Apple9 GPU family (A17/M3) or later,
  or Mac2.
- **Performance:** cost scales with points splatted (bounded per frame,
  evenly distributed across threads) rather than sort size or overdraw, so
  frame times stay flat as splat counts grow into the millions where the
  sorted pipelines degrade. Single frames are noisy; static views converge
  within tens of frames via accumulation. The per-frame point budget is
  derived automatically (32 points per supersampled pixel).

```swift
try PointSplatRenderPipeline(
    splatCloud: cloud,
    projectionMatrix: projectionMatrix,
    modelMatrix: .identity,
    cameraMatrix: cameraMatrix,
    drawableSize: size,
    frameIndex: frameIndex
)
```

## Usage

Rendering Gaussian splats requires two steps: sorting and rendering. The sort manager runs on a background thread and produces sorted indices that you pass to a render pipeline.

### Interactive Rendering (SwiftUI)

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

### Offline / Single-Frame Rendering

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

The render pipelines are pure rendering elements — they don't manage sorting or async state. The caller owns the `AsyncSortManager`, subscribes to its `sortedIndicesStream`, requests sorts when the camera moves, and passes the results in.

## Environment Variables

- `MSGS_SORT_LOG` — when set to `1`, `true`, `yes`, or `on`, the CPU splat
  sorter emits a per-frame info-level log line with the sort duration and
  splat count. Default is off (logs are noisy at frame rate). Slow-sort
  warnings (>16 ms) are always emitted regardless of this setting.

  Logs go to the unified logging system under subsystem
  `MetalSprocketsGaussianSplats`. Tail them in a terminal with:

  ```sh
  log stream --level info --predicate 'subsystem == "MetalSprocketsGaussianSplats"'
  ```

## License

MIT License. See LICENSE file for details.

## Acknowledgments

The two renderers in this project were based on work by the following projects. A big thanks to their authors for releasing their code under permissive licenses.

• [antimatter15](https://github.com/antimatter15/splat) (MIT license) — for the original GS renderer and the reference that basically everyone starts from.
• [sparkjs](http://sparkjs.dev) (MIT License)— for the clean implementation that makes porting sane.
