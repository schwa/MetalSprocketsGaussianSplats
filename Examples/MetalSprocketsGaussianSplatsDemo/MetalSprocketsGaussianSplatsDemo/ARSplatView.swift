#if os(iOS) && !arch(x86_64)
import ARKit
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Observation
import simd
import Splats
import SwiftUI

/// Owns the ARSession and republishes frames for SwiftUI (#43).
@Observable
@MainActor
final class ARSplatSessionModel: NSObject, ARSessionDelegate {
    let session = ARSession()
    var currentFrame: ARFrame?

    /// Latest-value stream from the ARKit delegate queue to the main actor.
    ///
    /// One consumer task drains the stream. Frames arrive in order. The stream
    /// drops stale frames instead of queueing unbounded work (#95).
    private let frameStream: AsyncStream<ARFrame>
    private let frameContinuation: AsyncStream<ARFrame>.Continuation

    override init() {
        (frameStream, frameContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
        session.delegate = self
        Task { [weak self] in
            guard let stream = self?.frameStream else {
                return
            }
            for await frame in stream {
                guard let self else {
                    return
                }
                self.currentFrame = frame
            }
        }
    }

    deinit {
        frameContinuation.finish()
    }

    func start() {
        session.run(ARWorldTrackingConfiguration())
    }

    func stop() {
        session.pause()
        currentFrame = nil
    }

    nonisolated func session(_: ARSession, didUpdate frame: ARFrame) {
        frameContinuation.yield(frame)
    }
}

/// Renders the splat cloud on top of the ARKit camera feed. The per-frame
/// view and projection matrices from ARKit keep the splat anchored in the
/// world (#43).
struct ARSplatView: View {
    let splatCloud: GPUSplatCloud<SparkSplat>

    /// Splat placed 1m in front of the session origin (the initial camera
    /// pose), scaled down to tabletop size.
    private static let modelMatrix = simd_float4x4(translation: [0, 0, -1]) * simd_float4x4(scale: [0.3, 0.3, 0.3])

    @State private var sessionModel = ARSplatSessionModel()
    @State private var frameData = ARFrameData()
    @State private var sortManager: AsyncSortManager<SparkSplat>?
    @State private var sortManagerError: Error?
    @State private var sortedIndices: SplatIndices?

    private static let pendingReleaseDepth = 3

    var body: some View {
        content
            .onAppear { sessionModel.start() }
            .onDisappear { sessionModel.stop() }
            .arkit(frame: sessionModel.currentFrame, frameData: $frameData)
            .task {
                // Created here, not in init. A failure then shows an error
                // message instead of a crash. No work runs on every parent
                // body evaluation (#98).
                let manager: AsyncSortManager<SparkSplat>
                do {
                    guard let device = MTLCreateSystemDefaultDevice() else {
                        throw ARSplatViewError.noMetalDevice
                    }
                    manager = try AsyncSortManager<SparkSplat>(
                        device: device,
                        splatCloud: splatCloud,
                        capacity: splatCloud.count,
                        preallocatedBufferCount: Self.pendingReleaseDepth + 3
                    )
                } catch {
                    sortManagerError = error
                    return
                }
                sortManager = manager
                for await indices in manager.managedSortedIndicesStream(pendingReleaseDepth: Self.pendingReleaseDepth) {
                    sortedIndices = indices
                }
            }
            .onChange(of: frameData.viewMatrix) {
                sortManager?.requestSort(SortParameters(camera: frameData.viewMatrix.inverse, model: Self.modelMatrix))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let textureY = frameData.textureY, let textureCbCr = frameData.textureCbCr {
            // Capture per-frame values so the render closure does not race teardown.
            let textureCoordinates = frameData.textureCoordinates
            let projectionMatrix = frameData.projectionMatrix
            let cameraMatrix = frameData.viewMatrix.inverse
            let sortedIndices = sortedIndices

            RenderView { _, drawableSize in
                let size = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
                try RenderPass {
                    YCbCrBillboardRenderPass(textureY: textureY, textureCbCr: textureCbCr, textureCoordinates: textureCoordinates)
                    if let sortedIndices {
                        try SparkSplatRenderPipeline(
                            splatCloud: splatCloud,
                            projectionMatrix: projectionMatrix,
                            modelMatrix: Self.modelMatrix,
                            cameraMatrix: cameraMatrix,
                            drawableSize: size,
                            sortedIndices: sortedIndices
                        )
                    }
                }
                .renderPassDescriptorModifier { descriptor in
                    descriptor.renderTargetArrayLength = 1
                }
            }
            .metalDepthStencilPixelFormat(.depth32Float)
            .metalClearColor(.init(red: 0, green: 0, blue: 0, alpha: 0))
        } else if let sortManagerError {
            ContentUnavailableView(
                "AR unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(sortManagerError.localizedDescription)
            )
        } else {
            ProgressView("Starting AR\u{2026}")
        }
    }
}

private enum ARSplatViewError: Error {
    case noMetalDevice
}
#endif
