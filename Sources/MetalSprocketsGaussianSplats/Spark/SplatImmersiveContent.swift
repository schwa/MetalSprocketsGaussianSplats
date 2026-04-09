#if os(visionOS)
import CompositorServices
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import Splats
internal import os
import SwiftUI

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
    let sortedIndices: SplatIndices?

    /// Creates an immersive splat element.
    ///
    /// - Parameters:
    ///   - context: The immersive context from the render content closure.
    ///   - splatCloud: The GPU splat cloud to render.
    ///   - modelMatrix: The model-to-world transform matrix.
    ///   - renderState: Shared render state that manages sorting across frames.
    public init(
        context: ImmersiveContext,
        splatCloud: GPUSplatCloud<SparkSplat>,
        modelMatrix: simd_float4x4 = .identity,
        renderState: SplatImmersiveRenderState
    ) throws {
        self.context = context
        self.splatCloud = splatCloud
        self.modelMatrix = modelMatrix

        let cameraMatrix = context.viewMatrix(eye: 0).inverse
        renderState.requestSort(cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
        self.sortedIndices = renderState.currentSortedIndices
    }

    nonisolated public var body: some Element {
        get throws {
            if let sortedIndices {
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

                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrices: projectionMatrices,
                    modelMatrix: modelMatrix,
                    cameraMatrices: cameraMatrices,
                    drawableSize: drawableSize,
                    convertSRGBToLinear: false,
                    sortedIndices: sortedIndices
                )
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

    private let sortManager: AsyncSortManager<SparkSplat>
    private let state: OSAllocatedUnfairLock<State>
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
}

#endif
