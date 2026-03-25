#if !arch(x86_64)
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import Splats
import SwiftUI

struct ContentView: View {
    @State private var cameraMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, 3))
    @State private var sortedIndices: SplatIndices?

    let splatCloud: GPUSplatCloud<SparkSplat>
    let sortManager: AsyncSortManager<SparkSplat>

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        let url = Bundle.main.url(forResource: "butterfly-wings-closed", withExtension: "spz")!
        let reader = try! SplatReader(url: url)
        var splats: [SparkSplat] = []
        splats.reserveCapacity(reader.splatCount)
        try! reader.read { _, extendedSplat in
            splats.append(SparkSplat(extendedSplat.genericSplat))
        }
        splatCloud = try! GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        sortManager = try! AsyncSortManager<SparkSplat>(device: device, splatCloud: splatCloud, capacity: splatCloud.count)
    }

    var body: some View {
        RenderView { _, drawableSize in
            let projection = PerspectiveProjection(
                verticalAngleOfView: .degrees(60),
                depthMode: .standard(zClip: 0.01 ... 1_000)
            )
            let projectionMatrix = projection.projectionMatrix(for: drawableSize)
            if let sortedIndices {
                try RenderPass {
                    try SparkSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrix: projectionMatrix,
                        modelMatrix: .identity,
                        cameraMatrix: cameraMatrix,
                        drawableSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
                        sortedIndices: sortedIndices
                    )
                }
                .renderPassDescriptorModifier { descriptor in
                    descriptor.renderTargetArrayLength = 1
                }
            }
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        .task {
            for await indices in sortManager.sortedIndicesStream {
                sortedIndices = indices
            }
        }
        .onChange(of: cameraMatrix, initial: true) {
            let parameters = SortParameters(camera: cameraMatrix, model: .identity)
            sortManager.requestSort(parameters)
        }
    }
}
#else
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Gaussian splat rendering requires Apple Silicon.")
    }
}
#endif
