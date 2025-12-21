#if os(visionOS)
import CompositorServices
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
import simd

struct GaussianSplatImmersiveContent: Element, @unchecked Sendable {
    let context: ImmersiveContext
    let splatCloud: GPUSplatCloud<SparkSplat>?
    let modelMatrix: simd_float4x4

    init(context: ImmersiveContext) throws {
        self.context = context
        self.splatCloud = ImmersiveState.shared.splatCloud
        self.modelMatrix = ImmersiveState.shared.modelMatrix
    }

    nonisolated var body: some Element {
        get throws {
            if let splatCloud {
                // Build view and projection matrices for stereo rendering
                let viewMatrices = (0 ..< context.viewCount).map { context.viewMatrix(eye: $0) }
                let projectionMatrices = (0 ..< context.viewCount).map { context.projectionMatrix(eye: $0) }
                let cameraMatrices = viewMatrices.map(\.inverse)

                // Position splat cloud in world space: 2m in front, 1.5m up, scaled to 30cm
                let worldModelMatrix = simd_float4x4(translation: [0, 1.5, -2])
                    * simd_float4x4(scale: [0.3, 0.3, 0.3])
                    * modelMatrix

                let drawableSize = SIMD2<Float>(
                    Float(context.drawable.colorTextures[0].width),
                    Float(context.drawable.colorTextures[0].height)
                )

                // Set up viewports for stereo rendering
                Draw { encoder in
                    var viewMappings = (0 ..< context.viewCount).map {
                        MTLVertexAmplificationViewMapping(
                            viewportArrayIndexOffset: UInt32($0),
                            renderTargetArrayIndexOffset: UInt32($0)
                        )
                    }
                    encoder.setVertexAmplificationCount(context.viewCount, viewMappings: &viewMappings)
                    encoder.setViewports(context.viewports)
                }

                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrices: projectionMatrices,
                    modelMatrix: worldModelMatrix,
                    cameraMatrices: cameraMatrices,
                    drawableSize: drawableSize,
                    convertSRGBToLinear: false
                )
                .depthCompare(function: .greater, enabled: true) // visionOS uses reverse-Z
                .renderPipelineDescriptorModifier { descriptor in
                    descriptor.maxVertexAmplificationCount = context.viewCount
                    descriptor.colorAttachments[0].pixelFormat = context.drawable.colorTextures[0].pixelFormat
                    descriptor.depthAttachmentPixelFormat = context.drawable.depthTextures[0].pixelFormat
                }
            }
        }
    }
}
#endif
