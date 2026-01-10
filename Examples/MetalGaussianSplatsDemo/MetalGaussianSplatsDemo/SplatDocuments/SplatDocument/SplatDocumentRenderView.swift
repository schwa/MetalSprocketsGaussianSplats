import GeometryLite3D
import Interaction3D
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import SwiftUI
import UniformTypeIdentifiers

struct SplatDocumentRenderView: View {
    let rendererType: SplatRendererType
    let descriptor: SplatCloudDescriptor
    let cameraMode: SplatDocumentViewModel.CameraMode
    let useSphericalHarmonics: Bool
    let backgroundColor: Color

    @Binding var cameraMatrix: simd_float4x4
    @Binding var modelMatrix: simd_float4x4
    @Binding var verticalAngleOfView: Double

    @State private var projection: (any ProjectionProtocol) = PerspectiveProjection(verticalAngleOfView: .degrees(90), depthMode: .standard(zClip: 0.01 ... 1_000))
    @State private var splatCloud: AnyGPUSplatCloud?

    var body: some View {
        Group {
            if let splatCloud {
                renderView(splatCloud: splatCloud)
            } else {
                ProgressView("Loading splat cloud...")
            }
        }
        .onChange(of: verticalAngleOfView, initial: true) {
            projection = PerspectiveProjection(verticalAngleOfView: .degrees(Float(verticalAngleOfView)), depthMode: .standard(zClip: 0.01 ... 1_000))
        }
        .onChange(of: descriptor.url, initial: true) {
            Task {
                let splatCloud = try! await loadSplatCloud()
                Task { @MainActor in
                    self.splatCloud = splatCloud
                    #if os(visionOS)
                    // Also update ImmersiveState with the SparkSplat cloud
                    if let sparkCloud = splatCloud.typed(as: SparkSplat.self) {
                        ImmersiveState.shared.splatCloud = sparkCloud
                    }
                    #endif
                }
            }
        }
        .onChange(of: rendererType) {
            Task {
                let splatCloud = try! await loadSplatCloud()
                Task { @MainActor in
                    self.splatCloud = splatCloud
                    #if os(visionOS)
                    // Also update ImmersiveState with the SparkSplat cloud
                    if let sparkCloud = splatCloud.typed(as: SparkSplat.self) {
                        ImmersiveState.shared.splatCloud = sparkCloud
                    }
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private func renderView(splatCloud: AnyGPUSplatCloud) -> some View {
        // Capture values to avoid accessing bindings from render thread
        let capturedCameraMatrix = cameraMatrix
        let capturedModelMatrix = modelMatrix
        let capturedProjection = projection
        let capturedRendererType = rendererType
        let capturedUseSphericalHarmonics = useSphericalHarmonics

        // Convert SwiftUI Color to MTLClearColor
        let resolvedColor = backgroundColor.resolve(in: EnvironmentValues())
        let clearColor = MTLClearColor(
            red: Double(resolvedColor.red),
            green: Double(resolvedColor.green),
            blue: Double(resolvedColor.blue),
            alpha: Double(resolvedColor.opacity)
        )

        let view = RenderView { context, drawableSize in
            SplatRenderPass(rendererType: capturedRendererType, splatCloud: splatCloud, cameraMatrix: capturedCameraMatrix, modelMatrix: capturedModelMatrix, projection: capturedProjection, drawableSize: drawableSize, frame: context.frameUniforms.index, useSphericalHarmonics: capturedUseSphericalHarmonics)
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalClearColor(clearColor)

        switch cameraMode {
        case .spatialScene:
            view.modifier(SpatialSceneCameraController(transform: $cameraMatrix))
        case .object, .room:
            view.modifier(TurntableCameraController(transform: $cameraMatrix))
        }
    }

    @concurrent
    private func loadSplatCloud() async throws -> AnyGPUSplatCloud {
        try await MainActor.run {
            try timeit("Load splat cloud") {
                switch rendererType {
                case .spark, .stochastic, .tileBased:
                    let cloud: GPUSplatCloud<SparkSplat> = try descriptor.loadGPUSplatCloud()
                    return AnyGPUSplatCloud(cloud)
                case .antimatter15:
                    let cloud: GPUSplatCloud<Antimatter15GPUSplat> = try descriptor.loadGPUSplatCloud()
                    return AnyGPUSplatCloud(cloud)
                }
            }
        }
    }
}
