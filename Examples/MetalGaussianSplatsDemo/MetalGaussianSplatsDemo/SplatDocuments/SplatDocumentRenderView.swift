#if !arch(x86_64)
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
    let url: URL

    @Environment(SplatDocumentViewModel.self) private var viewModel

    @State private var sparkSplatCloud: GPUSplatCloud<SparkSplat>?
    @State private var antimatter15SplatCloud: GPUSplatCloud<Antimatter15GPUSplat>?

    // Hardcoded transforms
    @State private var cameraMatrix: simd_float4x4 = .identity
    @State private var modelMatrix: simd_float4x4 = .identity
    @State private var projection: (any ProjectionProtocol) = PerspectiveProjection(verticalAngleOfView: .degrees(90), depthMode: .standard(zClip: 0.01 ... 1_000))

    var body: some View {
        ZStack {
            WorldView(projection: $projection, cameraMatrix: $cameraMatrix) {
                RenderView { context, drawableSize in
                    let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                    switch viewModel.rendererType {
                    case .spark:
                        if let splatCloud = sparkSplatCloud {
                            try RenderPass {
                                try SparkSplatRenderPipeline(
                                    splatCloud: splatCloud,
                                    projectionMatrix: projectionMatrix,
                                    modelMatrix: modelMatrix,
                                    cameraMatrix: cameraMatrix,
                                    drawableSize: SIMD2<Float>(drawableSize)
                                )
                            }
                        }
                    case .stochastic:
                        if let splatCloud = sparkSplatCloud {
                            try RenderPass {
                                try StochasticSplatRenderPipeline(
                                    splatCloud: splatCloud,
                                    projectionMatrix: projectionMatrix,
                                    modelMatrix: modelMatrix,
                                    cameraMatrix: cameraMatrix,
                                    drawableSize: SIMD2<Float>(drawableSize),
                                    frameTime: context.frameUniforms.index
                                )
                            }
                        }
                    case .antimatter15:
                        if let splatCloud = antimatter15SplatCloud {
                            try RenderPass {
                                try Antimatter15SplatRenderPipeline(
                                    splatCloud: splatCloud,
                                    projectionMatrix: projectionMatrix,
                                    modelMatrix: modelMatrix,
                                    cameraMatrix: cameraMatrix,
                                    drawableSize: SIMD2<Float>(drawableSize)
                                )
                            }
                        }
                    case .tileBased:
                        // TODO: TileBased requires multi-pass rendering
                        if let splatCloud = sparkSplatCloud {
                            try TileBasedSplatPass(splatCloud: splatCloud, projection: projection, drawableSize: SIMD2<Float>(drawableSize), cameraMatrix: cameraMatrix)
                        }
                    }
                }
                .metalColorPixelFormat(.bgra8Unorm_srgb)
                .metalClearColor(.init(red: 0, green: 0, blue: 0, alpha: 1))
            }
        }
        .onChange(of: url, initial: true) {
            loadGPUSplatCloud()
        }
        .onChange(of: viewModel.rendererType) {
            loadGPUSplatCloud()
        }
    }

    private func loadGPUSplatCloud() {
        guard let descriptor = viewModel.descriptor else { return }
        switch viewModel.rendererType {
        case .spark, .stochastic, .tileBased:
            sparkSplatCloud = try! descriptor.loadGPUSplatCloud(cameraMatrix: cameraMatrix)
        case .antimatter15:
            antimatter15SplatCloud = try! descriptor.loadGPUSplatCloud(cameraMatrix: cameraMatrix)
        }
    }
}

#else

struct SplatDocumentRenderView: View {
    let url: URL

    var body: some View {
        ContentUnavailableView(
            "Unsupported Platform",
            systemImage: "cpu",
            description: Text("Gaussian Splat rendering requires Apple Silicon")
        )
    }
}

#endif
