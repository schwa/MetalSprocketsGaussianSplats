#if os(visionOS)
import CompositorServices
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
internal import os
import simd
import Splats
import SwiftUI

/// Turnkey immersive space content that renders a Gaussian splat cloud.
///
/// Wraps `ImmersiveRenderContent`, `ImmersiveRenderPass`, ``SplatImmersiveElement``,
/// and ``SplatImmersiveRenderState`` so usage is a single line:
///
/// ```swift
/// ImmersiveSpace(id: "Splat") {
///     try! SplatImmersiveContent(splatCloud: cloud)
/// }
/// ```
///
/// For more control, use ``SplatImmersiveElement`` directly. It supports custom
/// render pass composition, frame timing callbacks, and mixing with other elements.
public struct SplatImmersiveContent: ImmersiveSpaceContent {
    let splatCloud: GPUSplatCloud<SparkSplat>
    let modelMatrix: simd_float4x4
    let renderer: SplatRenderer
    private let renderState: SplatImmersiveRenderState

    /// Creates turnkey immersive splat content.
    ///
    /// - Parameters:
    ///   - splatCloud: The GPU splat cloud to render.
    ///   - modelMatrix: The model-to-world transform matrix.
    ///   - renderer: The rendering algorithm to use.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        modelMatrix: simd_float4x4 = .identity,
        renderer: SplatRenderer = .sparkGPU
    ) throws {
        self.splatCloud = splatCloud
        self.modelMatrix = modelMatrix
        self.renderer = renderer
        self.renderState = try SplatImmersiveRenderState(splatCloud: splatCloud)
    }

    public var body: some ImmersiveSpaceContent {
        ImmersiveRenderContent { [splatCloud, modelMatrix, renderer, renderState] context in
            if renderer == .sparkGPU {
                // The GPU sort is a compute pass. Encode it before the render
                // pass, outside it.
                try SplatImmersiveGPUSortElement(
                    context: context,
                    splatCloud: splatCloud,
                    modelMatrix: modelMatrix,
                    renderState: renderState
                )
            }
            try ImmersiveRenderPass(context: context, label: "Splat") {
                try SplatImmersiveElement(
                    context: context,
                    splatCloud: splatCloud,
                    modelMatrix: modelMatrix,
                    renderer: renderer,
                    renderState: renderState
                )
            }
        }
    }
}

/// A MetalSprockets `Element` that renders a Gaussian splat cloud in a visionOS immersive space.
///
/// Use inside `ImmersiveRenderContent` and `ImmersiveRenderPass`, like any other
/// MetalSprockets element:
///
/// ```swift
/// ImmersiveSpace(id: "SplatSpace") {
///     ImmersiveRenderContent { context in
///         try ImmersiveRenderPass(context: context) {
///             try SplatImmersiveElement(
///                 context: context,
///                 splatCloud: splatCloud,
///                 modelMatrix: .identity
///             )
///         }
///     }
/// }
/// ```
///
/// Manages sorting internally through a shared ``SplatImmersiveRenderState``.
/// The first frame can render nothing while the first sort completes.
public struct SplatImmersiveElement: Element, @unchecked Sendable {
    let context: ImmersiveContext
    let splatCloud: GPUSplatCloud<SparkSplat>
    let modelMatrix: simd_float4x4
    let renderer: SplatRenderer
    let gpuSortedIndices: SplatIndices?
    let frameCount: UInt32

    /// Creates an immersive splat element.
    ///
    /// - Parameters:
    ///   - context: The immersive context from the render content closure.
    ///   - splatCloud: The GPU splat cloud to render.
    ///   - modelMatrix: The model-to-world transform matrix.
    ///   - renderer: The rendering algorithm to use.
    ///   - renderState: Shared render state that manages sorting across frames.
    public init(
        context: ImmersiveContext,
        splatCloud: GPUSplatCloud<SparkSplat>,
        modelMatrix: simd_float4x4 = .identity,
        renderer: SplatRenderer = .sparkGPU,
        renderState: SplatImmersiveRenderState
    ) throws {
        self.context = context
        self.splatCloud = splatCloud
        self.modelMatrix = modelMatrix
        self.renderer = renderer
        self.frameCount = renderState.nextFrameCount()

        self.gpuSortedIndices = renderer == .sparkGPU ? renderState.currentGPUSortIndices() : nil
    }

    nonisolated public var body: some Element {
        get throws {
            let viewMatrices = (0 ..< context.viewCount).map { context.viewMatrix(eye: $0) }
            let projectionMatrices = (0 ..< context.viewCount).map { context.projectionMatrix(eye: $0) }
            let cameraMatrices = viewMatrices.map(\.inverse)

            let drawableSize = SIMD2<Float>(
                Float(context.drawable.colorTextures[0].width),
                Float(context.drawable.colorTextures[0].height)
            )

            switch renderer {
            case .stochastic:
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
                try StochasticSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrices: projectionMatrices,
                    modelMatrix: modelMatrix,
                    cameraMatrices: cameraMatrices,
                    drawableSize: drawableSize,
                    frameTime: frameCount,
                    convertSRGBToLinear: true
                )
                .depthCompare(function: .greater, enabled: true)
                .renderPipelineDescriptorTransformer { descriptor in
                    descriptor.maxVertexAmplificationCount = context.viewCount
                    descriptor.colorAttachments[0].pixelFormat = context.drawable.colorTextures[0].pixelFormat
                    descriptor.depthAttachmentPixelFormat = context.drawable.depthTextures[0].pixelFormat
                }
            case .sparkGPU:
                // GPU-sorted path. It needs a ``SplatImmersiveGPUSortElement``
                // encoded before this render pass. ``SplatImmersiveContent``
                // does this automatically. It renders both eyes in one draw
                // through vertex amplification. The instance count of the
                // indirect draw is the number of splats that pass the cull.
                if let gpuSortedIndices {
                    Draw { encoder in
                        var viewMappings = (0 ..< context.viewCount).map {
                            MTLVertexAmplificationViewMapping(
                                viewportArrayIndexOffset: UInt32($0),
                                renderTargetArrayIndexOffset: 0
                            )
                        }
                        encoder.setVertexAmplificationCount(context.viewCount, viewMappings: &viewMappings)
                        encoder.setViewports(context.viewports)
                    }
                    try SparkSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrices: projectionMatrices,
                        modelMatrix: modelMatrix,
                        cameraMatrices: cameraMatrices,
                        drawableSize: drawableSize,
                        configuration: .init(convertSRGBToLinear: true),
                        sortedIndices: gpuSortedIndices
                    )
                    .viewMappings((0 ..< context.viewCount).map {
                        MTLVertexAmplificationViewMapping(
                            viewportArrayIndexOffset: UInt32($0),
                            renderTargetArrayIndexOffset: 0
                        )
                    })
                    .depthCompare(function: .greater, enabled: true)
                    .renderPipelineDescriptorTransformer { descriptor in
                        descriptor.maxVertexAmplificationCount = context.viewCount
                        descriptor.colorAttachments[0].pixelFormat = context.drawable.colorTextures[0].pixelFormat
                        descriptor.depthAttachmentPixelFormat = context.drawable.depthTextures[0].pixelFormat
                    }
                }
            case .tileBased, .pointSplat:
                // Not supported in immersive rendering.
                EmptyElement()
            }
        }
    }

}

// MARK: - GPU Sort Element

/// Encodes the GPU splat sort (frustum cull and radix sort) for immersive
/// rendering. Put it before ``ImmersiveRenderPass``. The sort is a compute
/// pass and cannot live inside a render pass:
///
/// ```swift
/// ImmersiveRenderContent { context in
///     try SplatImmersiveGPUSortElement(
///         context: context,
///         splatCloud: splatCloud,
///         modelMatrix: modelMatrix,
///         renderState: renderState
///     )
///     try ImmersiveRenderPass(context: context) {
///         try SplatImmersiveElement(..., renderer: .sparkGPU, renderState: renderState)
///     }
/// }
/// ```
///
/// The cull keeps splats visible to either eye. The sort key is the depth of
/// the left eye. ``SplatImmersiveElement`` reads the sorted indices from the
/// shared render state.
public struct SplatImmersiveGPUSortElement: Element, @unchecked Sendable {
    let splatCloud: GPUSplatCloud<SparkSplat>
    let projectionMatrices: [simd_float4x4]
    let modelMatrix: simd_float4x4
    let cameraMatrices: [simd_float4x4]
    private let resources: GPUSortResources
    private let slotIndex: Int

    public init(
        context: ImmersiveContext,
        splatCloud: GPUSplatCloud<SparkSplat>,
        modelMatrix: simd_float4x4 = .identity,
        renderState: SplatImmersiveRenderState
    ) throws {
        self.splatCloud = splatCloud
        self.modelMatrix = modelMatrix
        // The GPU sort supports at most two views.
        let viewCount = min(context.viewCount, 2)
        self.projectionMatrices = (0 ..< viewCount).map { context.projectionMatrix(eye: $0) }
        self.cameraMatrices = (0 ..< viewCount).map { context.viewMatrix(eye: $0).inverse }
        // Advance the slot in init, not body. The body can be re-evaluated
        // many times per frame.
        (self.resources, self.slotIndex) = try renderState.beginGPUSort(
            splatCloud: splatCloud,
            cameraMatrix: cameraMatrices[0],
            modelMatrix: modelMatrix
        )
    }

    public var body: some Element {
        get throws {
            try GPUSplatSortComputePass(
                splatCloud: splatCloud,
                projectionMatrices: projectionMatrices,
                modelMatrix: modelMatrix,
                cameraMatrices: cameraMatrices,
                resources: resources,
                slotIndex: slotIndex
            )
        }
    }
}

// MARK: - Render State

/// Thread-safe render state for immersive splat rendering that manages sorting across frames.
///
/// Create one of these and pass it to ``SplatImmersiveElement`` each frame.
///
/// ```swift
/// let renderState = try SplatImmersiveRenderState(splatCloud: splatCloud)
///
/// ImmersiveRenderContent { context in
///     try ImmersiveRenderPass(context: context) {
///         try SplatImmersiveElement(
///             context: context,
///             splatCloud: splatCloud,
///             renderState: renderState
///         )
///     }
/// }
/// ```
public final class SplatImmersiveRenderState: Sendable {
    /// Failures that occur when the render state is created.
    public enum Error: Swift.Error {
        /// No Metal device is available on this system.
        case noMetalDevice
    }

    private struct GPUSortState {
        var resources: GPUSortResources?
        var indices: SplatIndices?
    }

    private let gpuSortState: OSAllocatedUnfairLock<GPUSortState>
    private let frameCounter: OSAllocatedUnfairLock<UInt32>
    public init(splatCloud: GPUSplatCloud<SparkSplat>) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw Error.noMetalDevice
        }
        self.frameCounter = OSAllocatedUnfairLock(initialState: UInt32(0))
        let resources = try GPUSortResources(device: device, capacity: splatCloud.count)
        self.gpuSortState = OSAllocatedUnfairLock(uncheckedState: GPUSortState(resources: resources))
    }

    /// Prepares the shared GPU sort resources for a new frame. It creates them
    /// on first use, advances the frame slot, and publishes the ``SplatIndices``
    /// of the slot for ``SplatImmersiveElement`` to render with.
    func beginGPUSort(
        splatCloud: GPUSplatCloud<SparkSplat>,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4
    ) throws -> (GPUSortResources, Int) {
        try gpuSortState.withLockUnchecked { state in
            let resources: GPUSortResources
            if let existing = state.resources {
                resources = existing
            } else {
                let device = MTLCreateSystemDefaultDevice()!
                resources = try GPUSortResources(device: device, capacity: splatCloud.count)
                state.resources = resources
            }
            try resources.ensure(capacity: splatCloud.count)
            let slotIndex = resources.advance()
            state.indices = resources.makeIndices(
                slot: slotIndex,
                count: splatCloud.count,
                parameters: SortParameters(camera: cameraMatrix, model: modelMatrix)
            )
            return (resources, slotIndex)
        }
    }

    /// The ``SplatIndices`` published by the most recent ``beginGPUSort``, or
    /// `nil` if the GPU sort has not run this session.
    func currentGPUSortIndices() -> SplatIndices? {
        gpuSortState.withLockUnchecked { $0.indices }
    }

    public func nextFrameCount() -> UInt32 {
        frameCounter.withLock { count in
            count &+= 1
            return count
        }
    }
}

#endif
