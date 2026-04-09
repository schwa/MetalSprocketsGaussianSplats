#if os(visionOS)
import MetalSprocketsGaussianSplats
import SwiftUI

struct ImmersiveToggle: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isTransitioning = false
    @Bindable var demoState: DemoState

    var body: some View {
        Button(demoState.isImmersive ? "Exit Immersive" : "View in Immersive Space") {
            isTransitioning = true
            Task {
                if demoState.isImmersive {
                    await dismissImmersiveSpace()
                    demoState.isImmersive = false
                } else {
                    let result = await openImmersiveSpace(id: "SplatImmersive")
                    if case .opened = result {
                        demoState.isImmersive = true
                    }
                }
                isTransitioning = false
            }
        }
        .disabled(isTransitioning)
        .buttonStyle(.borderedProminent)
    }
}
#endif
