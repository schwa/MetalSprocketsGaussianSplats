# MetalSprockets Gaussian Splats

Gaussian Splat rendering built on [MetalSprockets](https://metalsprockets/com) ([Github](https://github.com/schwa/MetalSprockets)).

This repository includes both a standalone renderer and a Swift framework you can drop into your own project.

There’s also a CLI target for offline rendering. See the Justfile for how to drive it.

For anyone new the Wikipedia article is a great summary of the technique: [Wikipedia](https://en.wikipedia.org/wiki/Gaussian_splatting)

## Requirements

- Any current iOS device or Apple Silcon Mac.
- Currently requires macOS 26/iOS 26 - but can be backported with minimal effort.

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

## License

MIT License. See LICENSE file for details.

## Acknowledgments

The two renderers in this project were based on work by the following projects. A big thanks to their authors for releasing their code under permissive licenses.

• [antimatter15](https://github.com/antimatter15/splat) (MIT license) — for the original GS renderer and the reference that basically everyone starts from.
• [sparkjs](http://sparkjs.dev) (MIT License)— for the clean implementation that makes porting sane.
