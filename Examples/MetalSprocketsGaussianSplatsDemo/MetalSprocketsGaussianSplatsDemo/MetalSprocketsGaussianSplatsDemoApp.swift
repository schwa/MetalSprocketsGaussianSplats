import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Splats
import SwiftUI

@main
struct MetalSprocketsGaussianSplatsDemoApp: App {
    @State private var demoState = DemoState()

    var body: some Scene {
        WindowGroup {
            ContentView(splatCloud: demoState.splatCloud, demoState: demoState)
        }
        #if os(visionOS)
        SplatImmersiveScene(demoState: demoState)
        #endif
    }
}
