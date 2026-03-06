#if os(visionOS)
import SwiftUI

// TODO: visionOS SplatDocumentView needs to be reimplemented.
// The previous implementation referenced types (SplatDocumentViewModel, SplatRenderView,
// InspectorView, InspectorTab) that are only available on iOS/macOS.
struct SplatDocumentView: View {
    let document: SplatDocument
    let fileURL: URL?

    var body: some View {
        ContentUnavailableView(
            "visionOS Support Coming Soon",
            systemImage: "visionpro",
            description: Text("The visionOS document viewer is being reimplemented.")
        )
    }
}
#endif
