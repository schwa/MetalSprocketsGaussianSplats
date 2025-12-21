import GeometryLite3D
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import SwiftUI
import UniformTypeIdentifiers
import Interaction3D

struct SplatDocumentRenderView: View {
    let rendererType: SplatRendererType
    let descriptor: SplatCloudDescriptor
    let cameraMode: SplatDocumentViewModel.CameraMode

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
            let cameraMatrix = cameraMatrix
            Task {
                let splatCloud = try! await loadSplatCloud(cameraMatrix: cameraMatrix)
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
            let cameraMatrix = cameraMatrix
            Task {
                let splatCloud = try! await loadSplatCloud(cameraMatrix: cameraMatrix)
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
        .onChange(of: modelMatrix) {
            #if os(visionOS)
            ImmersiveState.shared.modelMatrix = modelMatrix
            #endif
        }
    }

    @ViewBuilder
    private func renderView(splatCloud: AnyGPUSplatCloud) -> some View {
        let view = RenderView { context, drawableSize in
            SplatRenderPass(rendererType: rendererType, splatCloud: splatCloud, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix, projection: projection, drawableSize: drawableSize, frame: context.frameUniforms.index)
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalClearColor(.init(red: 0, green: 0, blue: 0, alpha: 1))

        switch cameraMode {
        case .spatialScene:
            view.modifier(SpatialSceneCameraController(transform: $cameraMatrix))
        case .object, .room:
            view.modifier(TurntableCameraController(transform: $cameraMatrix))
        }
    }

    @concurrent
    private func loadSplatCloud(cameraMatrix: simd_float4x4) async throws -> AnyGPUSplatCloud {
        try timeit("Load splat cloud") {
            switch rendererType {
            case .spark, .stochastic, .tileBased:
                let cloud: GPUSplatCloud<SparkSplat> = try descriptor.loadGPUSplatCloud(cameraMatrix: cameraMatrix)
                return AnyGPUSplatCloud(cloud)
            case .antimatter15:
                let cloud: GPUSplatCloud<Antimatter15GPUSplat> = try descriptor.loadGPUSplatCloud(cameraMatrix: cameraMatrix)
                return AnyGPUSplatCloud(cloud)
            }
        }
    }
}
