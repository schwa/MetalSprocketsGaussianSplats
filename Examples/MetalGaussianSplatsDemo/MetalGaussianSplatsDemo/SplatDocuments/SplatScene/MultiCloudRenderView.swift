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

    @State private var projection: (any ProjectionProtocol) = PerspectiveProjection(verticalAngleOfView: .degrees(90), depthMode: .standard(zClip: 0.01 ... 1_000))

    var body: some View {
        RenderView { context, drawableSize in
            MultiCloudRenderPass(
                clouds: clouds,
                cameraMatrix: cameraMatrix,
                sceneTransform: sceneTransform,
                projection: projection,
                drawableSize: drawableSize,
                useSphericalHarmonics: useSphericalHarmonics
            )
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalClearColor(.init(red: 0, green: 0, blue: 0, alpha: 1))
        .modifier(TurntableCameraController(transform: $cameraMatrix))
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

    var body: some Element {
        get throws {
            let projectionMatrix = projection.projectionMatrix(for: drawableSize)
            try RenderPass {
                try SparkSplatRenderPipeline(
                    splatClouds: clouds,
                    projectionMatrices: [projectionMatrix],
                    modelMatrix: sceneTransform,
                    cameraMatrices: [cameraMatrix],
                    drawableSize: SIMD2<Float>(drawableSize),
                    useSphericalHarmonics: useSphericalHarmonics
                )
            }
        }
    }
}
#endif
