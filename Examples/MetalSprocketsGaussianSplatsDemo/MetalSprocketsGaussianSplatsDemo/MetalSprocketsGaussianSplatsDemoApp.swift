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
        let device = MTLCreateSystemDefaultDevice()!
        let url = Bundle.main.url(forResource: "butterfly-wings-closed", withExtension: "spz")!
        let reader = try! SplatReader(url: url)
        var splats: [SparkSplat] = []
        splats.reserveCapacity(reader.splatCount)
        try! reader.read { _, extendedSplat in
            splats.append(SparkSplat(extendedSplat.genericSplat))
        }
        let cloud = try! GPUSplatCloud<SparkSplat>(device: device, splats: splats)
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
