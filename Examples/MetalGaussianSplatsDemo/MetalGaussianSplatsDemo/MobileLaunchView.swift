#if os(iOS) || os(visionOS)
import SwiftUI

struct MobileLaunchView: View {
    @State private var showSettings = false

    @State private var openImport = false

    @Environment(\.openURL)
    private var openURL

    var body: some View {
        NavigationStack {
            documentLaunchView
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gear") {
                        showSettings = true
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }

    @ViewBuilder
    var documentLaunchView: some View {
        #if !os(visionOS)
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
        #else
        ZStack {
            Button("Open Document") {
                openImport = true
            }
            .fileImporter(isPresented: $openImport, allowedContentTypes: SplatDocument.readableContentTypes) { result in
                // This line intentionally left blank
            }
        }
        #endif
    }
}

#Preview {
    MobileLaunchView()
}
#endif
