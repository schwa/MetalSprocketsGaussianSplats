import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Splats
import SwiftUI

@main
struct MetalSprocketsGaussianSplatsDemoApp: App {
    let splatCloud: GPUSplatCloud<SparkSplat>
    @State private var demoState = DemoState()

    #if os(visionOS)
    let renderState: SplatImmersiveRenderState
    #endif

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
        #if os(visionOS)
        self.renderState = SplatImmersiveRenderState(splatCloud: cloud)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if os(visionOS)
            ContentView(splatCloud: splatCloud, demoState: demoState, renderState: renderState)
            #else
            ContentView(splatCloud: splatCloud, demoState: demoState)
            #endif
        }
        #if os(visionOS)
        SplatImmersiveScene(splatCloud: splatCloud, renderState: renderState, demoState: demoState)
        #endif
    }
}
