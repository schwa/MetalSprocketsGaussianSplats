#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
internal import os
import SwiftUI
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI

let sparkLogger: Logger? = Logger(subsystem: "spark-splats", category: "spark-splats")

public struct SparkSplatView<Splat: SortableSplatProtocol>: View {
    private var splatCloud: SplatCloud<Splat>
    private var projection: any ProjectionProtocol
    private var cameraMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4

    public init(splatCloud: SplatCloud<Splat>, projection: any ProjectionProtocol, cameraMatrix: simd_float4x4, modelMatrix: simd_float4x4 = .identity) {
        self.splatCloud = splatCloud
        self.projection = projection
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
    }

    public var body: some View {
        RenderView { _, drawableSize in
            try RenderPass {
                let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                try SparkSplatRenderPipeline(
                    splatCloud: splatCloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: SIMD2<Float>(drawableSize),
                    shCoefficients: nil,
                    shDegree: 0
                )
            }
        }
        .metalColorPixelFormat(.bgra8Unorm_srgb)
    }

}
#endif
