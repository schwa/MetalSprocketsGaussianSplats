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
///     SplatImmersiveContent(splatCloud: cloud)
/// }
/// ```
///
/// For more control (custom render pass composition, frame timing callbacks,
/// mixing with other elements), drop down to ``SplatImmersiveElement`` directly.
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
        renderer: SplatRenderer = .spark
    ) {
        self.splatCloud = splatCloud
        self.modelMatrix = modelMatrix
        self.renderer = renderer
        self.renderState = SplatImmersiveRenderState(splatCloud: splatCloud)
    }

    public var body: some ImmersiveSpaceContent {
        ImmersiveRenderContent { [splatCloud, modelMatrix, renderer, renderState] context in
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
/// Use inside `ImmersiveRenderContent` and `ImmersiveRenderPass`, exactly like any other
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
/// Manages sorting internally via a shared ``SplatImmersiveRenderState``.
/// The first frame may render nothing while the initial sort completes.
public struct SplatImmersiveElement: Element, @unchecked Sendable {
    let context: ImmersiveContext
    let splatCloud: GPUSplatCloud<SparkSplat>
    let modelMatrix: simd_float4x4
    let renderer: SplatRenderer
    let sortedIndicesPerEye: [SplatIndices?]
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
        renderer: SplatRenderer = .spark,
        renderState: SplatImmersiveRenderState
    ) throws {
        self.context = context
        self.splatCloud = splatCloud
        self.modelMatrix = modelMatrix
        self.renderer = renderer
        self.frameCount = renderState.nextFrameCount()

        if renderer == .spark {
            // Sort once per eye — CPU sorts are cheap and this eliminates any
            // depth-order disagreement between eyes for distant splats.
            let cameraMatrices = (0 ..< context.viewCount).map { context.viewMatrix(eye: $0).inverse }
            renderState.requestSort(cameraMatrices: cameraMatrices, modelMatrix: modelMatrix)
            self.sortedIndicesPerEye = (0 ..< context.viewCount).map { renderState.currentSortedIndices(eye: $0) }
        } else {
            self.sortedIndicesPerEye = []
        }
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
            case .spark:
                // Per-eye rendering: each eye gets its own draw with its own sort
                // order, targeting its render target layer via a view mapping.
                try eyeElement(eye: 0, projectionMatrices: projectionMatrices, cameraMatrices: cameraMatrices, drawableSize: drawableSize)
                if context.viewCount > 1 {
                    try eyeElement(eye: 1, projectionMatrices: projectionMatrices, cameraMatrices: cameraMatrices, drawableSize: drawableSize)
                }
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
                .renderPipelineDescriptorModifier { descriptor in
                    descriptor.maxVertexAmplificationCount = context.viewCount
                    descriptor.colorAttachments[0].pixelFormat = context.drawable.colorTextures[0].pixelFormat
                    descriptor.depthAttachmentPixelFormat = context.drawable.depthTextures[0].pixelFormat
                }
            case .gpu, .tileBased, .pointSplat:
                // Not supported in immersive rendering.
                EmptyElement()
            }
        }
    }

    private func eyeElement(eye: Int, projectionMatrices: [simd_float4x4], cameraMatrices: [simd_float4x4], drawableSize: SIMD2<Float>) throws -> some Element {
        try Group {
            if let sortedIndices = eye < sortedIndicesPerEye.count ? sortedIndicesPerEye[eye] : nil {
                Draw { [viewport = context.viewports[eye]] encoder in
                    encoder.setViewport(viewport)
                }
                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrices[eye],
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrices[eye],
                    drawableSize: drawableSize,
                    convertSRGBToLinear: true,
                    sortedIndices: sortedIndices
                )
                .viewMappings([
                    MTLVertexAmplificationViewMapping(
                        viewportArrayIndexOffset: UInt32(eye),
                        renderTargetArrayIndexOffset: UInt32(eye)
                    )
                ])
                .depthCompare(function: .greater, enabled: true)
                .renderPipelineDescriptorModifier { descriptor in
                    descriptor.maxVertexAmplificationCount = context.viewCount
                    descriptor.colorAttachments[0].pixelFormat = context.drawable.colorTextures[0].pixelFormat
                    descriptor.depthAttachmentPixelFormat = context.drawable.depthTextures[0].pixelFormat
                }
            }
        }
    }
}

// MARK: - Render State

/// Thread-safe render state for immersive splat rendering that manages sorting across frames.
///
/// Create one of these and pass it to ``SplatImmersiveElement`` each frame.
///
/// ```swift
/// let renderState = SplatImmersiveRenderState(splatCloud: splatCloud)
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
    private struct State: Sendable {
        var sortedIndices: SplatIndices?
        var pendingRelease: [SplatIndices] = []
    }

    // One sort manager and state slot per eye, so each eye has its own sort
    // order and buffer lifecycle.
    private let sortManagers: [AsyncSortManager<SparkSplat>]
    private let states: [OSAllocatedUnfairLock<State>]
    private let frameCounter: OSAllocatedUnfairLock<UInt32>
    private let listenerTasks: [Task<Void, Never>]

    private static let pendingReleaseDepth = 3
    private static let eyeCount = 2

    public init(splatCloud: GPUSplatCloud<SparkSplat>) {
        let device = MTLCreateSystemDefaultDevice()!
        var sortManagers: [AsyncSortManager<SparkSplat>] = []
        var states: [OSAllocatedUnfairLock<State>] = []
        var listenerTasks: [Task<Void, Never>] = []
        for _ in 0 ..< Self.eyeCount {
            let sortManager = try! AsyncSortManager<SparkSplat>(
                device: device,
                splatCloud: splatCloud,
                capacity: splatCloud.count,
                preallocatedBufferCount: Self.pendingReleaseDepth + 3
            )
            let state = OSAllocatedUnfairLock(initialState: State())
            sortManagers.append(sortManager)
            states.append(state)
            listenerTasks.append(Task {
                for await indices in sortManager.sortedIndicesStream {
                    let toRelease: SplatIndices? = state.withLock { state in
                        var release: SplatIndices?
                        if let old = state.sortedIndices {
                            state.pendingRelease.append(old)
                            if state.pendingRelease.count > Self.pendingReleaseDepth {
                                release = state.pendingRelease.removeFirst()
                            }
                        }
                        state.sortedIndices = indices
                        return release
                    }
                    if let toRelease {
                        sortManager.release(toRelease)
                    }
                }
            })
        }
        self.sortManagers = sortManagers
        self.states = states
        self.listenerTasks = listenerTasks
        self.frameCounter = OSAllocatedUnfairLock(initialState: UInt32(0))
    }

    deinit {
        for task in listenerTasks {
            task.cancel()
        }
    }

    /// Requests a sort for each eye's camera matrix. Matrices beyond the
    /// supported eye count are ignored.
    public func requestSort(cameraMatrices: [simd_float4x4], modelMatrix: simd_float4x4) {
        for (eye, cameraMatrix) in cameraMatrices.prefix(Self.eyeCount).enumerated() {
            sortManagers[eye].requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
        }
    }

    /// The most recent sorted indices for the given eye, or `nil` if no sort
    /// has completed yet.
    public func currentSortedIndices(eye: Int) -> SplatIndices? {
        guard eye >= 0, eye < states.count else {
            return nil
        }
        return states[eye].withLock { $0.sortedIndices }
    }

    public func nextFrameCount() -> UInt32 {
        frameCounter.withLock { count in
            count &+= 1
            return count
        }
    }
}

#endif
