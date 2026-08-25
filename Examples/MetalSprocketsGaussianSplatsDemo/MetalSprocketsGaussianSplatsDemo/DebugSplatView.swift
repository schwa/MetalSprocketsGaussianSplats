#if !arch(x86_64)
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatsDebug
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import simd
import Splats
import SwiftUI

struct DebugSplatView: View {
    let splatCloud: GPUSplatCloud<SparkSplat>
    let cameraMatrix: simd_float4x4
    let debugParams: DebugParams

    @State private var resources: GPUSortResources

    init(splatCloud: GPUSplatCloud<SparkSplat>, cameraMatrix: simd_float4x4, debugParams: DebugParams) {
        self.splatCloud = splatCloud
        self.cameraMatrix = cameraMatrix
        self.debugParams = debugParams
        let device = splatCloud.splats.unsafeMTLBuffer.device
        _resources = State(initialValue: try! GPUSortResources(device: device, capacity: splatCloud.count))
    }

    var body: some View {
        RenderView { _, drawableSize in
            let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01 ... 1_000))
            try GPUSortedSplatDebugRenderPipeline(
                splatCloud: splatCloud,
                projectionMatrix: projection.projectionMatrix(for: drawableSize),
                modelMatrix: .identity,
                cameraMatrix: cameraMatrix,
                drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                debugParams: debugParams,
                resources: resources
            )
        }
    }
}
#endif
