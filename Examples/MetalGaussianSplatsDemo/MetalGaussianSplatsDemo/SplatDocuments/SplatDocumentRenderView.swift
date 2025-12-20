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

//    let rendererType: SplatRendererType
//    let descriptor: SplatCloudDescriptor

    // Hardcoded transforms
    @State private var cameraMatrix: simd_float4x4 = .identity
    @State private var modelMatrix: simd_float4x4 = .identity
    @State private var projection: (any ProjectionProtocol) = PerspectiveProjection(verticalAngleOfView: .degrees(90), depthMode: .standard(zClip: 0.01 ... 1_000))

    var body: some View {
        ZStack {
            WorldView(projection: $projection, cameraMatrix: $cameraMatrix) {
                RenderView { context, drawableSize in
                    SplatRenderPass(rendererType: viewModel.rendererType, descriptor: viewModel.descriptor!, drawableSize: drawableSize, frame: context.frameUniforms.index)
                }
                .metalColorPixelFormat(.bgra8Unorm_srgb)
                .metalClearColor(.init(red: 0, green: 0, blue: 0, alpha: 1))
            }
        }
    }
}

struct SplatRenderPass: Element {
    let rendererType: SplatRendererType
    let descriptor: SplatCloudDescriptor

    // Hardcoded transforms
    var cameraMatrix: simd_float4x4 = .identity
    var modelMatrix: simd_float4x4 = .identity
    var projection: (any ProjectionProtocol) = PerspectiveProjection(verticalAngleOfView: .degrees(90), depthMode: .standard(zClip: 0.01 ... 1_000))
    var drawableSize: CGSize
    var frame: UInt32

    @MSState private var sparkSplatCloud: GPUSplatCloud<SparkSplat>?
    @MSState private var antimatter15SplatCloud: GPUSplatCloud<Antimatter15GPUSplat>?

    var body: some Element {
        get throws {
            try Group {
                let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                switch rendererType {
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
                                frameTime: frame
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
            .onChange(of: descriptor.url, initial: true) { _, _ in
                loadGPUSplatCloud()
            }
            // TODO: This isn't accurate as some renderes share splat types
            .onChange(of: rendererType) { _, _ in
                loadGPUSplatCloud()
            }
        }
    }

    private func loadGPUSplatCloud() {
        timeit("Load splat cloud") {
            switch rendererType {
            case .spark, .stochastic, .tileBased:
                sparkSplatCloud = try! descriptor.loadGPUSplatCloud(cameraMatrix: cameraMatrix)
            case .antimatter15:
                antimatter15SplatCloud = try! descriptor.loadGPUSplatCloud(cameraMatrix: cameraMatrix)
            }
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
