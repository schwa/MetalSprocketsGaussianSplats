#if os(iOS) && !os(visionOS)
import SwiftUI

struct MobileLaunchView: View {
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            DocumentLaunchView(
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
            .navigationTitle("Gaussian Splats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gear") {
                        showSettings = true
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                MobileSettingsView()
            }
        }
    }
}

#Preview {
    MobileLaunchView()
}
#endif
