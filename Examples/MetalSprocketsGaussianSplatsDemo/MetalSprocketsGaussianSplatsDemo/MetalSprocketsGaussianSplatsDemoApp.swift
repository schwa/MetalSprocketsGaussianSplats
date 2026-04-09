#if os(visionOS)
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Splats
#endif
import SwiftUI

@main
struct MetalSprocketsGaussianSplatsDemoApp: App {
    #if os(visionOS)
    let splatCloud: GPUSplatCloud<SparkSplat>
    let renderState: SplatImmersiveRenderState

    init() {
        let cloud = loadSplatCloud()
        self.splatCloud = cloud
        self.renderState = SplatImmersiveRenderState(splatCloud: cloud)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(visionOS)
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
        #endif
    }
}
