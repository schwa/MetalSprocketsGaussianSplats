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
    let sortedIndices: SplatIndices?
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
            // Average both eyes' positions for sort — minimizes worst-case depth error for stereo
            let cam0 = context.viewMatrix(eye: 0).inverse
            let cam1 = context.viewCount > 1 ? context.viewMatrix(eye: 1).inverse : cam0
            let avgPosition = (cam0.columns.3 + cam1.columns.3) * 0.5
            var cameraMatrix = cam0
            cameraMatrix.columns.3 = avgPosition
            renderState.requestSort(cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
            self.sortedIndices = renderState.currentSortedIndices
        } else {
            self.sortedIndices = nil
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

            switch renderer {
            case .spark:
                if let sortedIndices {
                    try SparkSplatRenderPipeline(
                        splatCloud: splatCloud,
                        projectionMatrices: projectionMatrices,
                        modelMatrix: modelMatrix,
                        cameraMatrices: cameraMatrices,
                        drawableSize: drawableSize,
                        convertSRGBToLinear: true,
                        sortedIndices: sortedIndices
                    )
                    .depthCompare(function: .greater, enabled: true)
                    .renderPipelineDescriptorModifier { descriptor in
                        descriptor.maxVertexAmplificationCount = context.viewCount
                        descriptor.colorAttachments[0].pixelFormat = context.drawable.colorTextures[0].pixelFormat
                        descriptor.depthAttachmentPixelFormat = context.drawable.depthTextures[0].pixelFormat
                    }
                }
            case .stochastic:
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

    private let sortManager: AsyncSortManager<SparkSplat>
    private let state: OSAllocatedUnfairLock<State>
    private let frameCounter: OSAllocatedUnfairLock<UInt32>
    private let listenerTask: Task<Void, Never>

    private static let pendingReleaseDepth = 3

    public init(splatCloud: GPUSplatCloud<SparkSplat>) {
        let device = MTLCreateSystemDefaultDevice()!
        let sortManager = try! AsyncSortManager<SparkSplat>(
            device: device,
            splatCloud: splatCloud,
            capacity: splatCloud.count,
            preallocatedBufferCount: Self.pendingReleaseDepth + 3
        )
        self.sortManager = sortManager
        let state = OSAllocatedUnfairLock(initialState: State())
        self.state = state
        self.frameCounter = OSAllocatedUnfairLock(initialState: UInt32(0))

        self.listenerTask = Task {
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
        }
    }

    deinit {
        listenerTask.cancel()
    }

    public func requestSort(cameraMatrix: simd_float4x4, modelMatrix: simd_float4x4) {
        let parameters = SortParameters(camera: cameraMatrix, model: modelMatrix)
        sortManager.requestSort(parameters)
    }

    public var currentSortedIndices: SplatIndices? {
        state.withLock { $0.sortedIndices }
    }

    public func nextFrameCount() -> UInt32 {
        frameCounter.withLock { count in
            count &+= 1
            return count
        }
    }
}

#endif
