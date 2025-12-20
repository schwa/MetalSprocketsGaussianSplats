import GeometryLite3D
import Interaction3D
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import SwiftUI
import UniformTypeIdentifiers

struct SplatRenderPass: Element {
    let rendererType: SplatRendererType
    let descriptor: SplatCloudDescriptor

    var cameraMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
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
