#if !arch(x86_64)

import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import Splats

/// A self-contained splat pipeline. It sorts on the GPU, culls the frustum, and
/// renders in the same GPU workload. It does no CPU sort and needs no ``AsyncSortManager``.
///
/// Each frame encodes a ``GPUSplatSortComputePass`` into one slot of a shared
/// ``GPUSortResources``. It then renders through ``SparkSplatRenderPipeline`` with an
/// indirect draw. The instance count is the number of splats that pass the cull.
///
/// ``SparkSplatRenderPipeline`` runs inside a `RenderPass`. This element owns its own
/// `ComputePass` and `RenderPass`, so put it at the top level of the frame:
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
/// - Important: The frames-in-flight count of the caller must not be more than
///   ``GPUSortResources/slotCount`` (default 3). If it is more, the slots race.
public struct GPUSortedSplatRenderPipeline: Element {
    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var drawableSize: SIMD2<Float>
    var convertSRGBToLinear: Bool
    var useSphericalHarmonics: Bool?
    var debugParams: DebugParams?
    var cullEnabled: Bool
    var guardBand: Float
    var resources: GPUSortResources

    /// Creates a pipeline for mono (single-view) rendering.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        convertSRGBToLinear: Bool = true,
        useSphericalHarmonics: Bool? = nil,
        debugParams: DebugParams? = nil,
        cullEnabled: Bool = true,
        guardBand: Float = 0.2,
        resources: GPUSortResources
    ) throws {
        try self.init(
            splatCloud: splatCloud,
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            drawableSize: drawableSize,
            convertSRGBToLinear: convertSRGBToLinear,
            useSphericalHarmonics: useSphericalHarmonics,
            debugParams: debugParams,
            cullEnabled: cullEnabled,
            guardBand: guardBand,
            resources: resources
        )
    }

    /// Creates a pipeline for stereo (amplification) rendering. With two views
    /// the GPU cull keeps splats visible to either eye. The render uses vertex
    /// amplification into a layered render target.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrices: [simd_float4x4],
        modelMatrix: simd_float4x4,
        cameraMatrices: [simd_float4x4],
        drawableSize: SIMD2<Float>,
        convertSRGBToLinear: Bool = true,
        useSphericalHarmonics: Bool? = nil,
        debugParams: DebugParams? = nil,
        cullEnabled: Bool = true,
        guardBand: Float = 0.2,
        resources: GPUSortResources
    ) throws {
        precondition(!projectionMatrices.isEmpty, "Must have at least one projection matrix")
        precondition(projectionMatrices.count == cameraMatrices.count, "projectionMatrices and cameraMatrices must have the same count")
        self.splatCloud = splatCloud
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.drawableSize = drawableSize
        self.convertSRGBToLinear = convertSRGBToLinear
        self.useSphericalHarmonics = useSphericalHarmonics
        self.debugParams = debugParams
        self.cullEnabled = cullEnabled
        self.guardBand = guardBand
        self.resources = resources
        try resources.ensure(capacity: splatCloud.count)
        // Advance the frame slot here, not in body. The element is constructed
        // once per frame. The body can be re-evaluated many times through
        // diffing and re-expansion, which uses up the frames-in-flight slots.
        slotIndex = resources.advance()
        sortedIndices = resources.makeIndices(
            slot: slotIndex,
            count: splatCloud.count,
            parameters: SortParameters(camera: cameraMatrices[0], model: modelMatrix)
        )
    }

    private let slotIndex: Int
    private let sortedIndices: SplatIndices

    public var body: some Element {
        get throws {
            let viewCount = cameraMatrices.count
            try GPUSplatSortComputePass(
                splatCloud: splatCloud,
                projectionMatrices: projectionMatrices,
                modelMatrix: modelMatrix,
                cameraMatrices: cameraMatrices,
                cullEnabled: cullEnabled,
                guardBand: guardBand,
                resources: resources,
                slotIndex: slotIndex
            )

            try RenderPass {
                if let debugParams {
                    try SparkSplatDebugRenderPipeline(
                        splatClouds: [splatCloud],
                        projectionMatrices: projectionMatrices,
                        modelMatrix: modelMatrix,
                        cameraMatrices: cameraMatrices,
                        drawableSize: drawableSize,
                        debugParams: debugParams,
                        sortedIndices: sortedIndices
                    )
                } else {
                    try SparkSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrices: projectionMatrices,
                        modelMatrix: modelMatrix,
                        cameraMatrices: cameraMatrices,
                        drawableSize: drawableSize,
                        configuration: .init(convertSRGBToLinear: convertSRGBToLinear, useSphericalHarmonics: useSphericalHarmonics),
                        sortedIndices: sortedIndices
                    )
                }
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.renderTargetArrayLength = viewCount
            }
        }
    }
}

#endif
