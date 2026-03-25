#if !arch(x86_64)
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import SwiftUI

struct SplatPreviewView: View {
    let splatCloud: GPUSplatCloud<SparkSplat>
    let sortManager: AsyncSortManager<SparkSplat>

    @State private var cameraMatrix = simd_float4x4(translation: [0, 0, 5])
    @State private var sortedIndices: SplatIndices?
    private let modelMatrix = simd_float4x4(xRotation: .radians(.pi))
    private let projection = PerspectiveProjection(
        verticalAngleOfView: .degrees(90),
        depthMode: .standard(zClip: 0.01 ... 1_000)
    )

    init(splatCloud: GPUSplatCloud<SparkSplat>) throws {
        self.splatCloud = splatCloud
        let device = MTLCreateSystemDefaultDevice()!
        self.sortManager = try AsyncSortManager(device: device, splatClouds: [splatCloud], capacity: splatCloud.count)
    }

    var body: some View {
        RenderView { _, drawableSize in
            let projectionMatrix = projection.projectionMatrix(for: drawableSize)
            if let sortedIndices {
                try RenderPass {
                    try SparkSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrix: projectionMatrix,
                        modelMatrix: modelMatrix,
                        cameraMatrix: cameraMatrix,
                        drawableSize: SIMD2<Float>(drawableSize),
                        sortedIndices: sortedIndices
                    )
                }
            }
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalClearColor(.init(red: 0, green: 0, blue: 0, alpha: 1))
        .task {
            for await indices in sortManager.sortedIndicesStream {
                sortedIndices = indices
            }
        }
        .onChange(of: cameraMatrix, initial: true) {
            let parameters = SortParameters(camera: cameraMatrix, model: modelMatrix)
            sortManager.requestSort(parameters)
        }
    }
}
#endif
