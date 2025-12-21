#if os(iOS) && !os(visionOS)
import SwiftUI

struct MobileLaunchView: View {
    var body: some View {
o        DocumentLaunchView(
            "Gaussian Splats",
            for: SplatDocument.readableContentTypes
        ) {
            // No new document button - viewer only
        } onDocumentOpen: { url in
            SplatDocumentView(
                document: SplatDocument(),
                fileURL: url
            )
        }
    }
}

#Preview {
    MobileLaunchView()
}
#endif
