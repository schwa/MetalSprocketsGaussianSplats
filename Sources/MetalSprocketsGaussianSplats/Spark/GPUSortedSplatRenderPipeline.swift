#if !arch(x86_64)

import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import Splats

/// Self-contained splat pipeline: GPU sort (+ frustum cull) and render in the
/// same GPU workload, with no CPU sorting or ``AsyncSortManager``.
///
/// Each frame it encodes a ``GPUSplatSortComputePass`` into one slot of a shared
/// ``GPUSortResources``, then renders via ``SparkSplatRenderPipeline`` using an
/// indirect draw whose instance count is the cull survivor count.
///
/// Unlike ``SparkSplatRenderPipeline`` (used *inside* a `RenderPass`), this
/// element owns its own `ComputePass` + `RenderPass`, so place it at the top
/// level of the frame:
///
/// ```swift
/// RenderView { _, drawableSize in
///     try GPUSortedSplatRenderPipeline(
///         splatCloud: cloud,
///         projectionMatrix: projectionMatrix,
///         modelMatrix: .identity,
///         cameraMatrix: cameraMatrix,
///         drawableSize: SIMD2<Float>(drawableSize),
///         resources: sortResources
///     )
/// }
/// ```
///
/// - Important: The caller's frames-in-flight must not exceed
///   ``GPUSortResources/slotCount`` (default 3), or slots will race.
public struct GPUSortedSplatRenderPipeline: Element {
    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>
    var convertSRGBToLinear: Bool
    var useSphericalHarmonics: Bool?
    var cullEnabled: Bool
    var guardBand: Float
    var resources: GPUSortResources

    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        convertSRGBToLinear: Bool = true,
        useSphericalHarmonics: Bool? = nil,
        cullEnabled: Bool = true,
        guardBand: Float = 0.2,
        resources: GPUSortResources
    ) throws {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.convertSRGBToLinear = convertSRGBToLinear
        self.useSphericalHarmonics = useSphericalHarmonics
        self.cullEnabled = cullEnabled
        self.guardBand = guardBand
        self.resources = resources
        try resources.ensure(capacity: splatCloud.count)
        // Advance the frame slot here, not in body: the element is
        // constructed once per frame, while body can be re-evaluated
        // multiple times (diffing/re-expansion), which would burn through
        // the frames-in-flight slot rotation.
        slotIndex = resources.advance()
        sortedIndices = resources.makeIndices(
            slot: slotIndex,
            count: splatCloud.count,
            parameters: SortParameters(camera: cameraMatrix, model: modelMatrix)
        )
    }

    private let slotIndex: Int
    private let sortedIndices: SplatIndices

    public var body: some Element {
        get throws {
            try GPUSplatSortComputePass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                cullEnabled: cullEnabled,
                guardBand: guardBand,
                resources: resources,
                slotIndex: slotIndex
            )

            try RenderPass {
                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: drawableSize,
                    convertSRGBToLinear: convertSRGBToLinear,
                    useSphericalHarmonics: useSphericalHarmonics,
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
