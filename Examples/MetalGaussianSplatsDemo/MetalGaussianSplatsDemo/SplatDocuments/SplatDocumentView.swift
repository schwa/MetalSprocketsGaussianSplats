import SwiftUI

/// A view for displaying a single Gaussian Splat document
struct SplatDocumentView: View {
    let document: SplatDocument
    let fileURL: URL?

    @State private var viewModel = SplatDocumentViewModel()
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .info
    @State private var confirmedLoad = false
    @State private var showScreenshotSheet = false

    @Environment(\.displayScale) private var displayScale

    private var needsConfirmation: Bool {
        guard let descriptor = viewModel.descriptor else {
            return false
        }
        return descriptor.splatCount >= 1_000_000 && !confirmedLoad
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
                if let descriptor = viewModel.descriptor, !needsConfirmation {
                    SplatDocumentRenderView(
                        rendererType: viewModel.rendererType,
                        descriptor: descriptor,
                        cameraMatrix: $viewModel.cameraMatrix,
                        modelMatrix: $viewModel.modelMatrix,
                        verticalAngleOfView: $viewModel.verticalAngleOfView
                    )
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
            SplatDocumentInspectorView(tab: $inspectorTab)
                .environment(viewModel)
        }
        .focusedSceneValue(\.inspectorVisibility, $showInspector)
        .focusedSceneValue(\.inspectorTab, $inspectorTab)
        .toolbar {
            ToolbarItem {
                Button("Screenshot", systemImage: "camera") {
                    showScreenshotSheet = true
                }
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") {
                    showInspector.toggle()
                }
            }
        }
        .sheet(isPresented: $showScreenshotSheet) {
            ScreenshotSheet(
                defaultWidth: Int(viewModel.viewSize.width * displayScale),
                defaultHeight: Int(viewModel.viewSize.height * displayScale)
            )
        }
        .onChange(of: fileURL, initial: true) { _, newURL in
            confirmedLoad = false
            Task {
                await viewModel.load(url: newURL, contentType: document.contentType)
            }
        }
    }
}
