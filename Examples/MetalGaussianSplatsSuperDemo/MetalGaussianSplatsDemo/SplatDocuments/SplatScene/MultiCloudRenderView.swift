#if os(iOS) || os(macOS)
import GeometryLite3D
import Interaction3D
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import SwiftUI

// MARK: - Multi-Cloud Render View

struct MultiCloudRenderView: View {
    let clouds: [GPUSplatCloud<SparkSplat>]

    let cameraMatrix: simd_float4x4
    let sceneTransform: simd_float4x4
    let verticalAngleOfView: Double
    let useSphericalHarmonics: Bool
    let backgroundColor: [Float]
    var cullBoundingBox: BoundingBox3D?
    var sortManager: AsyncSortManager<SparkSplat>

    // Debug rendering
    var debugParams: DebugParams?

    // FPS tracking callback
    var onFrame: (() -> Void)?

    // Sorting control
    var sortingEnabled: Bool = true

    @State private var sortedIndices: SplatIndices?
    @State private var projection: (any ProjectionProtocol) = PerspectiveProjection(verticalAngleOfView: .degrees(90), depthMode: .standard(zClip: 0.01 ... 1_000))

    private var clearColor: MTLClearColor {
        guard backgroundColor.count == 4 else {
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }
        return MTLClearColor(
            red: Double(backgroundColor[0]),
            green: Double(backgroundColor[1]),
            blue: Double(backgroundColor[2]),
            alpha: Double(backgroundColor[3])
        )
    }

    var body: some View {
        RenderView { _, drawableSize in
            onFrame?()
            return MultiCloudRenderPass(
                clouds: clouds,
                cameraMatrix: cameraMatrix,
                sceneTransform: sceneTransform,
                projection: projection,
                drawableSize: drawableSize,
                useSphericalHarmonics: useSphericalHarmonics,
                cullBoundingBox: cullBoundingBox,
                sortedIndices: sortedIndices,
                debugParams: debugParams
            )
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalClearColor(clearColor)
        .task {
            for await indices in sortManager.sortedIndicesStream {
                sortedIndices = indices
            }
        }
        .onChange(of: cameraMatrix, initial: true) {
            if sortingEnabled {
                requestSort()
            }
        }
        .onChange(of: sceneTransform) {
            if sortingEnabled {
                requestSort()
            }
        }
        .onChange(of: verticalAngleOfView, initial: true) {
            projection = PerspectiveProjection(verticalAngleOfView: .degrees(Float(verticalAngleOfView)), depthMode: .standard(zClip: 0.01 ... 1_000))
        }
    }

    private func requestSort() {
        let parameters = SortParameters(camera: cameraMatrix, model: sceneTransform)
        sortManager.requestSort(parameters)
    }
}

struct MultiCloudRenderPass: Element {
    let clouds: [GPUSplatCloud<SparkSplat>]
    let cameraMatrix: simd_float4x4
    let sceneTransform: simd_float4x4
    let projection: any ProjectionProtocol
    let drawableSize: CGSize
    let useSphericalHarmonics: Bool
    var cullBoundingBox: BoundingBox3D?
    var sortedIndices: SplatIndices?

    // Debug rendering
    var debugParams: DebugParams?

    var body: some Element {
        get throws {
            if !clouds.isEmpty, let sortedIndices {
                let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                try RenderPass {
                    if let debugParams {
                        try SparkSplatDebugRenderPipeline(
                            splatClouds: clouds,
                            projectionMatrices: [projectionMatrix],
                            modelMatrix: sceneTransform,
                            cameraMatrices: [cameraMatrix],
                            drawableSize: SIMD2<Float>(drawableSize),
                            debugParams: debugParams,
                            boundingBox: cullBoundingBox,
                            sortedIndices: sortedIndices
                        )
                    } else {
                        try SparkSplatRenderPipeline(
                            splatClouds: clouds,
                            projectionMatrices: [projectionMatrix],
                            modelMatrix: sceneTransform,
                            cameraMatrices: [cameraMatrix],
                            drawableSize: SIMD2<Float>(drawableSize),
                            useSphericalHarmonics: useSphericalHarmonics,
                            boundingBox: cullBoundingBox,
                            sortedIndices: sortedIndices
                        )
                    }
                }
            } else {
                try RenderPass {
                    // Empty render pass - just to get the clear color.
                }
            }
        }
    }
}
#endif
