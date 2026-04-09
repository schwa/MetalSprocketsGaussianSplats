#if os(visionOS)
import GeometryLite3D
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Splats
import SwiftUI

struct SplatImmersiveScene: Scene {
    let splatCloud: GPUSplatCloud<SparkSplat>
    let renderState: SplatImmersiveRenderState

    var body: some Scene {
        ImmersiveSpace(id: "SplatImmersive") {
            ImmersiveRenderContent { [splatCloud, renderState] context in
                try ImmersiveRenderPass(context: context, label: "Splat") {
                    try SplatImmersiveElement(
                        context: context,
                        splatCloud: splatCloud,
                        modelMatrix: simd_float4x4(translation: SIMD3<Float>(0, 1.5, -2))
                            * simd_float4x4(xRotation: .radians(.pi)),
                        renderState: renderState
                    )
                }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
#endif
