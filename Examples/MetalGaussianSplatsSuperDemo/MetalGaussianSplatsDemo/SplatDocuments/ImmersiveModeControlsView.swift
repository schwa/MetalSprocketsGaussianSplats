#if os(visionOS)
import SwiftUI

// TODO: ImmersiveModeControlsView needs to be reimplemented once visionOS SplatDocumentView is restored.
struct ImmersiveModeControlsView: View {
    let onExitImmersive: () -> Void

    var body: some View {
        ContentUnavailableView(
            "Immersive Mode Unavailable",
            systemImage: "visionpro",
            description: Text("Immersive mode controls are being reimplemented.")
        )
    }
}
#endif
