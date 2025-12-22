#if os(iOS) || os(macOS)
import SwiftUI

/// A view for displaying a single Gaussian Splat document (iOS/macOS)
struct SplatDocumentView: View {
    let document: SplatDocument
    let fileURL: URL?

    @State private var viewModel = SplatDocumentViewModel()
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .info
    @State private var confirmedLoad = false
    @State private var showScreenshotSheet = false
    @State private var showExportDialog = false

    @Environment(\.displayScale) private var displayScale

    private var needsConfirmation: Bool {
        guard let descriptor = viewModel.descriptor else {
            return false
        }
        if viewModel.isImageConversion {
            return false
        }
        return descriptor.splatCount >= 1_000_000 && !confirmedLoad
    }

    var body: some View {
        Group {
            switch viewModel.loadingState {
            case .idle, .loading:
                ContentUnavailableView("Loading…", systemImage: "circle.dotted")
            case .converting(let status):
                if let sourceImage = viewModel.sourceImage {
                    ImageConversionView(sourceImage: sourceImage, statusMessage: status)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(2)
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                }
            case .error(let message):
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .ready:
                readyContent
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { viewModel.viewSize = $0 }
        .inspector(isPresented: $showInspector) {
            SplatDocumentInspectorView(tab: $inspectorTab)
                .environment(viewModel)
        }
        .focusedSceneValue(\.inspectorVisibility, $showInspector)
        .focusedSceneValue(\.inspectorTab, $inspectorTab)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showScreenshotSheet) {
            ScreenshotSheet(
                defaultWidth: Int(viewModel.viewSize.width * displayScale),
                defaultHeight: Int(viewModel.viewSize.height * displayScale)
            )
            .environment(viewModel)
        }
        .fileExporter(
            isPresented: $showExportDialog,
            document: viewModel.convertedURL.map { PLYFileDocument(url: $0) },
            contentType: .ply,
            defaultFilename: viewModel.convertedURL?.deletingPathExtension().lastPathComponent
        ) { _ in }
        .onChange(of: fileURL, initial: true) { _, newURL in
            confirmedLoad = false
            Task {
                await viewModel.load(url: newURL, contentType: document.contentType)
            }
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let descriptor = viewModel.descriptor, !needsConfirmation {
            SplatDocumentRenderView(
                rendererType: viewModel.rendererType,
                descriptor: descriptor,
                cameraMode: viewModel.cameraMode,
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.isImageConversion, viewModel.convertedURL != nil {
            ToolbarItem {
                Button("Export PLY", systemImage: "square.and.arrow.down") {
                    showExportDialog = true
                }
            }
        }
        ToolbarItem {
            Button("Screenshot", systemImage: "camera") {
                showScreenshotSheet = true
            }
        }
        #if os(iOS)
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.right") {
                showInspector.toggle()
            }
        }
        #else
        ToolbarItem {
            Button("Inspector", systemImage: "sidebar.right") {
                showInspector.toggle()
            }
        }
        #endif
    }
}
#endif
