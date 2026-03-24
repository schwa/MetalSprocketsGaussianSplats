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
    let sortedIndices: SplatIndices?
    let modelMatrix: simd_float4x4
    let scale: Float
    let translation: SIMD3<Float>

    init(context: ImmersiveContext) throws {
        self.context = context
        self.splatCloud = ImmersiveState.shared.splatCloud
        self.sortedIndices = ImmersiveState.shared.sortedIndices
        self.modelMatrix = ImmersiveState.shared.modelMatrix
        self.scale = ImmersiveState.shared.scale
        self.translation = ImmersiveState.shared.translation

        // Update head tracking info for recenter functionality
        // Use the first eye's view matrix to get head position/orientation
        let viewMatrix = context.viewMatrix(eye: 0)
        let cameraMatrix = viewMatrix.inverse
        let headPosition = SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z)
        let headForward = -SIMD3<Float>(cameraMatrix.columns.2.x, cameraMatrix.columns.2.y, cameraMatrix.columns.2.z)
        ImmersiveState.shared.headPosition = headPosition
        ImmersiveState.shared.headForward = headForward

        // Request sort with current camera
        ImmersiveState.shared.requestSort(cameraMatrix: cameraMatrix)
    }

    nonisolated var body: some Element {
        get throws {
            if let splatCloud, let sortedIndices {
                // Build view and projection matrices for stereo rendering
                let viewMatrices = (0 ..< context.viewCount).map { context.viewMatrix(eye: $0) }
                let projectionMatrices = (0 ..< context.viewCount).map { context.projectionMatrix(eye: $0) }
                let cameraMatrices = viewMatrices.map(\.inverse)

                let worldModelMatrix = simd_float4x4(translation: translation)
                    * simd_float4x4(scale: SIMD3<Float>(repeating: scale))
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
                    convertSRGBToLinear: false,
                    sortedIndices: sortedIndices
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
