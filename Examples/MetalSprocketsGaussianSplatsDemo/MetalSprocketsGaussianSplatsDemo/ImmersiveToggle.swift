#if os(visionOS)
import SwiftUI

struct ImmersiveToggle: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isImmersive = false
    @State private var isTransitioning = false

    var body: some View {
        Button(isImmersive ? "Exit Immersive" : "View in Immersive Space") {
            isTransitioning = true
            Task {
                if isImmersive {
                    await dismissImmersiveSpace()
                    isImmersive = false
                } else {
                    let result = await openImmersiveSpace(id: "SplatImmersive")
                    if case .opened = result {
                        isImmersive = true
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
