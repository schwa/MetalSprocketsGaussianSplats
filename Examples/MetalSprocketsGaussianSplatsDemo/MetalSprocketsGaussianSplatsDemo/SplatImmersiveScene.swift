#if os(visionOS)
import GeometryLite3D
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Splats
import SwiftUI

struct SplatImmersiveScene: Scene {
    let demoState: DemoState

    var body: some Scene {
        ImmersiveSpace(id: "SplatImmersive") {
            ImmersiveRenderContent { [demoState] context in
                let splatCloud = demoState.splatCloud
                let renderState = demoState.renderState
                let modelMatrix = simd_float4x4(translation: SIMD3<Float>(0, 1.5, -2))
                    * simd_float4x4(xRotation: .radians(.pi))
                if demoState.renderer == .sparkGPU {
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
                        renderer: demoState.renderer,
                        renderState: renderState
                    )
                }
            }
            .onFrameTimingChange { [weak demoState] statistics in
                Task { @MainActor in
                    demoState?.immersiveFrameTiming = statistics
                }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
#endif
