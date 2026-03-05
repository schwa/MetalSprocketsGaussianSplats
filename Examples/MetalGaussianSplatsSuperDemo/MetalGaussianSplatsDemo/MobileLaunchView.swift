#if os(iOS) || os(visionOS)
import SwiftUI

struct MobileLaunchView: View {
    @State private var showSettings = false

    @State private var openImport = false

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
        VStack(spacing: 24) {
            Spacer()

            Image(.splatCloud)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)

            Text("Gaussian Splats")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Open a splat file to view it in mixed reality")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                openImport = true
            } label: {
                Label("Open Document", systemImage: "doc.badge.plus")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(40)
        .fileImporter(isPresented: $openImport, allowedContentTypes: SplatDocument.readableContentTypes) { _ in
            // Document opening is handled by the system
        }
        #endif
    }
}

#Preview {
    MobileLaunchView()
}
#endif
