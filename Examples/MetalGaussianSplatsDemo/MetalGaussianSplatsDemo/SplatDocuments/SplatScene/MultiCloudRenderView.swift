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

    @Binding var cameraMatrix: simd_float4x4
    let sceneTransform: simd_float4x4
    @Binding var verticalAngleOfView: Double
    let useSphericalHarmonics: Bool
    let backgroundColor: [Float]
    var cullBoundingBox: BoundingBox3D?

    // Debug rendering
    var debugParams: DebugParams?

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
            MultiCloudRenderPass(
                clouds: clouds,
                cameraMatrix: cameraMatrix,
                sceneTransform: sceneTransform,
                projection: projection,
                drawableSize: drawableSize,
                useSphericalHarmonics: useSphericalHarmonics,
                cullBoundingBox: cullBoundingBox,
                debugParams: debugParams
            )
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalClearColor(clearColor)
        //        .modifier(TurntableCameraController(transform: $cameraMatrix))
        .onChange(of: verticalAngleOfView, initial: true) {
            projection = PerspectiveProjection(verticalAngleOfView: .degrees(Float(verticalAngleOfView)), depthMode: .standard(zClip: 0.01 ... 1_000))
        }
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

    // Debug rendering
    var debugParams: DebugParams?

    var body: some Element {
        get throws {
            if !clouds.isEmpty {
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
                            boundingBox: cullBoundingBox
                        )
                    } else {
                        try SparkSplatRenderPipeline(
                            splatClouds: clouds,
                            projectionMatrices: [projectionMatrix],
                            modelMatrix: sceneTransform,
                            cameraMatrices: [cameraMatrix],
                            drawableSize: SIMD2<Float>(drawableSize),
                            useSphericalHarmonics: useSphericalHarmonics,
                            boundingBox: cullBoundingBox
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
