import SwiftUI

/// A view for displaying a single Gaussian Splat document
struct SplatDocumentView: View {
    let document: SplatDocument
    let fileURL: URL?

    @State private var viewModel = SplatDocumentViewModel()
    @State private var showInspector = false
    @State private var confirmedLoad = false

    private var needsConfirmation: Bool {
        guard let descriptor = viewModel.descriptor else { return false }
        return descriptor.splatCount >= 1_000_000 && !confirmedLoad
    }

    /// The URL to use for rendering (converted URL for images, original for splats)
    private var renderURL: URL? {
        viewModel.convertedURL ?? fileURL
    }

    var body: some View {
        Group {
            switch viewModel.loadingState {
            case .idle, .loading:
                ContentUnavailableView("Loading…", systemImage: "circle.dotted")
            case .converting:
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Converting image with Sharp…")
                        .foregroundStyle(.secondary)
                }
            case .error(let message):
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .ready:
                if let renderURL, !needsConfirmation {
                    SplatDocumentRenderView(url: renderURL)
                        .environment(viewModel)
                        .ignoresSafeArea()
                } else if needsConfirmation {
                    ContentUnavailableView {
                        Label("Large Splat Cloud", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text("This file contains \(viewModel.descriptor!.splatCount.formatted()) splats which may take a while to load and could impact performance.")
                    } actions: {
                        Button("Load Anyway") {
                            confirmedLoad = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView("No file to render", systemImage: "questionmark")
                }
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { viewModel.viewSize = $0 }
        .inspector(isPresented: $showInspector) {
            SplatDocumentInspectorView()
                .environment(viewModel)
        }
        .toolbar {
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") {
                    showInspector.toggle()
                }
            }
        }
        .onChange(of: fileURL, initial: true) { _, newURL in
            confirmedLoad = false
            Task {
                await viewModel.load(url: newURL, contentType: document.contentType)
            }
        }
    }
}
