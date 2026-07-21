#if os(iOS) && !arch(x86_64)
import ARKit
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Splats
import Observation
import simd
import SwiftUI

/// Owns the ARSession and republishes frames for SwiftUI (#43).
@Observable
@MainActor
final class ARSplatSessionModel: NSObject, ARSessionDelegate {
    let session = ARSession()
    var currentFrame: ARFrame?

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        session.run(ARWorldTrackingConfiguration())
    }

    func stop() {
        session.pause()
        currentFrame = nil
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in currentFrame = frame }
    }
}

/// Renders the splat cloud on top of the ARKit camera feed, using ARKit's
/// per-frame view/projection matrices so the splat stays anchored in the
/// world (#43).
struct ARSplatView: View {
    let splatCloud: GPUSplatCloud<SparkSplat>

    /// Splat placed 1m in front of the session origin (the initial camera
    /// pose), scaled down to tabletop size.
    private static let modelMatrix = simd_float4x4(translation: [0, 0, -1]) * simd_float4x4(scale: [0.3, 0.3, 0.3])

    @State private var sessionModel = ARSplatSessionModel()
    @State private var frameData = ARFrameData()
    @State private var sortManager: AsyncSortManager<SparkSplat>
    @State private var sortedIndices: SplatIndices?

    private static let pendingReleaseDepth = 3

    init(splatCloud: GPUSplatCloud<SparkSplat>) {
        self.splatCloud = splatCloud
        // swiftlint:disable:next MTLCreateSystemDefaultDevice
        let device = MTLCreateSystemDefaultDevice()!
        _sortManager = State(initialValue: try! AsyncSortManager<SparkSplat>(
            device: device,
            splatCloud: splatCloud,
            capacity: splatCloud.count,
            preallocatedBufferCount: Self.pendingReleaseDepth + 3
        ))
    }

    var body: some View {
        content
            .onAppear { sessionModel.start() }
            .onDisappear { sessionModel.stop() }
            .arkit(frame: sessionModel.currentFrame, frameData: $frameData)
            .task {
                for await indices in sortManager.managedSortedIndicesStream(pendingReleaseDepth: Self.pendingReleaseDepth) {
                    sortedIndices = indices
                }
            }
            .onChange(of: frameData.viewMatrix) {
                sortManager.requestSort(SortParameters(camera: frameData.viewMatrix.inverse, model: Self.modelMatrix))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let textureY = frameData.textureY, let textureCbCr = frameData.textureCbCr {
            // Capture per-frame values so the render closure doesn't race teardown.
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
        } else {
            ProgressView("Starting AR\u{2026}")
        }
    }
}
#endif
