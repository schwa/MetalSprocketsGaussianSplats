#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
internal import os
import SwiftUI

public struct Antimatter15SplatView: View {
    private var splatCloud: SplatCloud<Antimatter15GPUSplat>
    private var projection: any ProjectionProtocol
    private var cameraMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4
    private var debugMode: Antimatter15SplatRenderPipeline.DebugMode

    public init(splatCloud: SplatCloud<Antimatter15GPUSplat>, projection: any ProjectionProtocol, cameraMatrix: simd_float4x4, modelMatrix: simd_float4x4 = .identity, debugMode: Antimatter15SplatRenderPipeline.DebugMode = .off) {
        self.splatCloud = splatCloud
        self.projection = projection
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
        self.debugMode = debugMode
    }

    public var body: some View {
        RenderView { _, drawableSize in
            try RenderPass {
                let projectionMatrix = projection.projectionMatrix(for: drawableSize)
                try Antimatter15SplatRenderPipeline(splatCloud: splatCloud, projectionMatrix: projectionMatrix, modelMatrix: modelMatrix, cameraMatrix: cameraMatrix, drawableSize: SIMD2<Float>(drawableSize), debugMode: debugMode)
            }
        }
    }
}
#endif
