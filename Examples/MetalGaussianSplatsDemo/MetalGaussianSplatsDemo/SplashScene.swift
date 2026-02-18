import SwiftUI

#if os(macOS)
struct SplashScene: Scene {
    var body: some Scene {
        Window("Welcome", id: "splash") {
            SplashView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

struct SplashView: View {
    @Environment(\.openDocument)
    private var openDocument

    @Environment(\.dismissWindow)
    private var dismissWindow

    @State
    private var selectedURL: URL?

    @State
    private var isFileImporterPresented = false

    private var recentDocumentURLs: [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left panel - branding and actions
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 20) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .glimmer(
                            sweepDuration: 1.5,
                            pauseDuration: 5.0,
                            gradientWidth: 0.3,
                            maxLightness: 0.3,
                            angle: 35.0
                        )
                        .accessibilityHidden(true)

                    Text("Gaussian Splats")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("View and explore 3D Gaussian splats")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Spacer()

                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Open File…", systemImage: "folder")
                        .frame(width: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: SplatDocument.readableContentTypes + SplatSceneDocument.readableContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    if case let .success(urls) = result, let url = urls.first {
                        // Start accessing the security-scoped resource
                        guard url.startAccessingSecurityScopedResource() else {
                            return
                        }
                        openFile(at: url)
                        // Note: We don't stop accessing here because the document system needs continued access
                    }
                }
                .padding(.bottom, 40)
            }
            .frame(width: 240)
            .background(.ultraThinMaterial)

            // Right panel - recent documents
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent Documents")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                Divider()

                if recentDocumentURLs.isEmpty {
                    ContentUnavailableView {
                        Label("No Recent Documents", systemImage: "clock")
                    } description: {
                        Text("Documents you open will appear here")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedURL) {
                        ForEach(Array(recentDocumentURLs.enumerated()), id: \.element) { index, url in
                            RecentDocumentRow(url: url, index: index)
                                .tag(url)
                                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 12))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 0)
                    .onChange(of: selectedURL) { _, newValue in
                        if let url = newValue {
                            openFile(at: url)
                        }
                    }
                }
            }
            .frame(width: 360)
            .background(.background)
        }
        .frame(width: 600, height: 400)
    }

    private func openFile(at url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: "splash")
            } catch {
                // Document open failed - system will show alert
            }
        }
    }
}

struct RecentDocumentRow: View {
    let url: URL
    let index: Int

    var body: some View {
        HStack {
            // File icon
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityLabel(Text("File: \(url.deletingPathExtension().lastPathComponent)"))

            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.body)
                    .lineLimit(1)

                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Keyboard shortcut hint for first 9 items
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .modifier(KeyboardShortcutModifier(index: index))
    }
}

struct KeyboardShortcutModifier: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9 {
            content.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        } else {
            content
        }
    }
}

#Preview {
    SplashView()
}
#endif
