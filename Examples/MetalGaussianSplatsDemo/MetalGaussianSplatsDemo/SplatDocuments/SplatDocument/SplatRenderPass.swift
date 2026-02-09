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
    let splatCloud: AnyGPUSplatCloud

    var cameraMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var projection: any ProjectionProtocol
    var drawableSize: CGSize
    var frame: UInt32
    var useSphericalHarmonics: Bool
    var cullBoundingBox: BoundingBox3D?

    var body: some Element {
        get throws {
            let projectionMatrix = projection.projectionMatrix(for: drawableSize)
            switch rendererType {
            case .spark:
                if let typedCloud = splatCloud.typed(as: SparkSplat.self) {
                    try RenderPass {
                        try SparkSplatRenderPipeline(
                            splatCloud: typedCloud,
                            projectionMatrix: projectionMatrix,
                            modelMatrix: modelMatrix,
                            cameraMatrix: cameraMatrix,
                            drawableSize: SIMD2<Float>(drawableSize),
                            useSphericalHarmonics: useSphericalHarmonics,
                            boundingBox: cullBoundingBox
                        )
                    }
                }
            case .stochastic:
                if let typedCloud = splatCloud.typed(as: SparkSplat.self) {
                    try RenderPass {
                        try StochasticSplatRenderPipeline(
                            splatCloud: typedCloud,
                            projectionMatrix: projectionMatrix,
                            modelMatrix: modelMatrix,
                            cameraMatrix: cameraMatrix,
                            drawableSize: SIMD2<Float>(drawableSize),
                            frameTime: frame,
                            useSphericalHarmonics: useSphericalHarmonics
                        )
                    }
                }
            case .antimatter15:
                if let typedCloud = splatCloud.typed(as: Antimatter15GPUSplat.self) {
                    try RenderPass {
                        try Antimatter15SplatRenderPipeline(
                            splatCloud: typedCloud,
                            projectionMatrix: projectionMatrix,
                            modelMatrix: modelMatrix,
                            cameraMatrix: cameraMatrix,
                            drawableSize: SIMD2<Float>(drawableSize)
                        )
                    }
                }
            case .tileBased:
                if let typedCloud = splatCloud.typed(as: SparkSplat.self) {
                    try TileBasedSplatPass(splatCloud: typedCloud, projection: projection, drawableSize: SIMD2<Float>(drawableSize), cameraMatrix: cameraMatrix)
                }
            }
        }
    }
}
