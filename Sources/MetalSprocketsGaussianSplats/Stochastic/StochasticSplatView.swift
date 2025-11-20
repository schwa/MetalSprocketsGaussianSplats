#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
internal import os
import SwiftUI
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI

private let stochasticLogger: Logger? = Logger(subsystem: "stochastic-splats", category: "stochastic-splats")

public struct StochasticSplatView<Splat: SortableSplatProtocol>: View {
    private var splatCloud: SplatCloud<Splat>
    private var projection: any ProjectionProtocol
    private var cameraMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4

    @State private var frameCounter: UInt32 = 0

    public init(
        splatCloud: SplatCloud<Splat>,
        projection: any ProjectionProtocol,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity
    ) {
        self.splatCloud = splatCloud
        self.projection = projection
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            // Use truncated time to avoid overflow - only need temporal variation
            let time = UInt32(truncatingIfNeeded: Int(timeline.date.timeIntervalSince1970 * 60))
            renderView(time: time)
        }
    }

    @ViewBuilder
    private func renderView(time: UInt32) -> some View {
        RenderView { _, drawableSize in
            try RenderPass {
                let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                try StochasticSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(drawableSize),
                    frameTime: time,
                    shCoefficients: nil,
                    shDegree: 0
                )
            }
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
        .metalDepthStencilPixelFormat(.depth32Float)
    }
}
#endif
