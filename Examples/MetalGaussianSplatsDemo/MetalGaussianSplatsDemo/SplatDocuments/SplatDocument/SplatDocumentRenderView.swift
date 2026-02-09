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
                SplatRenderContent(
                    splatCloud: splatCloud,
                    rendererType: rendererType,
                    cameraMode: cameraMode,
                    useSphericalHarmonics: useSphericalHarmonics,
                    backgroundColor: backgroundColor,
                    cameraMatrix: $cameraMatrix,
                    modelMatrix: modelMatrix,
                    projection: projection
                )
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
                    if let sparkCloud = splatCloud.typed(as: SparkSplat.self) {
                        ImmersiveState.shared.splatCloud = sparkCloud
                    }
                    #endif
                }
            }
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

// MARK: - Render Content View

private struct SplatRenderContent: View {
    let splatCloud: AnyGPUSplatCloud
    let rendererType: SplatRendererType
    let cameraMode: SplatDocumentViewModel.CameraMode
    let useSphericalHarmonics: Bool
    let backgroundColor: Color
    @Binding var cameraMatrix: simd_float4x4
    let modelMatrix: simd_float4x4
    let projection: any ProjectionProtocol

    var body: some View {
        let resolvedColor = backgroundColor.resolve(in: EnvironmentValues())
        let clearColor = MTLClearColor(
            red: Double(resolvedColor.red),
            green: Double(resolvedColor.green),
            blue: Double(resolvedColor.blue),
            alpha: Double(resolvedColor.opacity)
        )

        RenderView { [splatCloud, rendererType, cameraMatrix, modelMatrix, projection, useSphericalHarmonics] context, drawableSize in
            SplatRenderPass(
                rendererType: rendererType,
                splatCloud: splatCloud,
                cameraMatrix: cameraMatrix,
                modelMatrix: modelMatrix,
                projection: projection,
                drawableSize: drawableSize,
                frame: context.frameUniforms.index,
                useSphericalHarmonics: useSphericalHarmonics
            )
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalClearColor(clearColor)
        .modifier(CameraControllerModifier(cameraMode: cameraMode, cameraMatrix: $cameraMatrix))
    }
}

// MARK: - Camera Controller Modifier

private struct CameraControllerModifier: ViewModifier {
    let cameraMode: SplatDocumentViewModel.CameraMode
    @Binding var cameraMatrix: simd_float4x4

    func body(content: Content) -> some View {
        switch cameraMode {
        case .spatialScene:
            content.modifier(SpatialSceneCameraController(transform: $cameraMatrix))
        case .object, .room:
            content.interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        }
    }
}
