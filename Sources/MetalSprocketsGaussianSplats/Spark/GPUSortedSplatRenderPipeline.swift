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
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var drawableSize: SIMD2<Float>
    var convertSRGBToLinear: Bool
    var useSphericalHarmonics: Bool?
    var cullEnabled: Bool
    var guardBand: Float
    var resources: GPUSortResources

    /// Convenience initializer for mono (single-view) rendering.
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
        try self.init(
            splatCloud: splatCloud,
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            drawableSize: drawableSize,
            convertSRGBToLinear: convertSRGBToLinear,
            useSphericalHarmonics: useSphericalHarmonics,
            cullEnabled: cullEnabled,
            guardBand: guardBand,
            resources: resources
        )
    }

    /// Full initializer supporting stereo/amplification rendering. With two
    /// views the GPU cull keeps splats visible to either eye, and the render
    /// uses vertex amplification into a layered render target.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrices: [simd_float4x4],
        modelMatrix: simd_float4x4,
        cameraMatrices: [simd_float4x4],
        drawableSize: SIMD2<Float>,
        convertSRGBToLinear: Bool = true,
        useSphericalHarmonics: Bool? = nil,
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
                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrices: projectionMatrices,
                    modelMatrix: modelMatrix,
                    cameraMatrices: cameraMatrices,
                    drawableSize: drawableSize,
                    convertSRGBToLinear: convertSRGBToLinear,
                    useSphericalHarmonics: useSphericalHarmonics,
                    sortedIndices: sortedIndices
                )
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.renderTargetArrayLength = viewCount
            }
        }
    }
}

#endif
