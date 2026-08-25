#if !arch(x86_64)
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

public struct GPUSortedSplatDebugRenderPipeline: Element {
    private let splatCloud: GPUSplatCloud<SparkSplat>
    private let projectionMatrix: simd_float4x4
    private let modelMatrix: simd_float4x4
    private let cameraMatrix: simd_float4x4
    private let drawableSize: SIMD2<Float>
    private let debugParams: DebugParams
    private let resources: GPUSortResources
    private let slotIndex: Int
    private let sortedIndices: SplatIndices

    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, debugParams: DebugParams, resources: GPUSortResources) throws {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.debugParams = debugParams
        self.resources = resources
        try resources.ensure(capacity: splatCloud.count)
        slotIndex = resources.advance()
        sortedIndices = resources.makeIndices(slot: slotIndex, count: splatCloud.count, parameters: SortParameters(camera: cameraMatrix, model: modelMatrix))
    }

    public var body: some Element {
        get throws {
            try GPUSplatSortComputePass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                resources: resources,
                slotIndex: slotIndex
            )
            try RenderPass {
                try SparkSplatDebugRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: drawableSize,
                    debugParams: debugParams,
                    sortedIndices: sortedIndices
                )
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.renderTargetArrayLength = 1
            }
        }
    }
}
#endif
