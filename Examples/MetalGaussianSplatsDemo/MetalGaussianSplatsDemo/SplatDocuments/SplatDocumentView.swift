import SwiftUI

#if os(visionOS)
import MetalSprocketsGaussianSplats
#endif

/// A view for displaying a single Gaussian Splat document
struct SplatDocumentView: View {
    let document: SplatDocument
    let fileURL: URL?

    @State private var viewModel = SplatDocumentViewModel()
    @State private var showInspector = false
    @State private var inspectorTab: InspectorTab = .info
    @State private var confirmedLoad = false
    @State private var showScreenshotSheet = false
    @State private var showExportDialog = false
    #if !os(macOS)
    @State private var showSettings = false
    #endif

    #if os(visionOS)
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersiveState = ImmersiveState.shared
    #endif

    @Environment(\.displayScale) private var displayScale

    private var needsConfirmation: Bool {
        guard let descriptor = viewModel.descriptor else {
            return false
        }
        // Skip confirmation for image conversions (they produce small splat clouds)
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
                if let descriptor = viewModel.descriptor, !needsConfirmation {
                    #if os(visionOS)
                    if immersiveState.isImmersive {
                        ContentUnavailableView {
                            Label("Immersive Mode Active", systemImage: "visionpro")
                        } description: {
                            Text("Look around you to see the splat cloud in immersive space.")
                        }
                    } else {
                        SplatDocumentRenderView(
                            rendererType: viewModel.rendererType,
                            descriptor: descriptor,
                            cameraMode: viewModel.cameraMode,
                            cameraMatrix: $viewModel.cameraMatrix,
                            modelMatrix: $viewModel.modelMatrix,
                            verticalAngleOfView: $viewModel.verticalAngleOfView
                        )
                        .ignoresSafeArea()
                    }
                    #else
                    SplatDocumentRenderView(
                        rendererType: viewModel.rendererType,
                        descriptor: descriptor,
                        cameraMode: viewModel.cameraMode,
                        cameraMatrix: $viewModel.cameraMatrix,
                        modelMatrix: $viewModel.modelMatrix,
                        verticalAngleOfView: $viewModel.verticalAngleOfView
                    )
                    .ignoresSafeArea()
                    #endif
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
        #if os(visionOS)
        .focusedSceneValue(\.inspectorVisibility, $showInspector)
        .focusedSceneValue(\.inspectorTab, $inspectorTab)
        #else
        .inspector(isPresented: $showInspector) {
        SplatDocumentInspectorView(tab: $inspectorTab)
        .environment(viewModel)
        }
        .focusedSceneValue(\.inspectorVisibility, $showInspector)
        .focusedSceneValue(\.inspectorTab, $inspectorTab)
        #endif
        .toolbar {
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
            #if os(visionOS)
            ToolbarItem {
                Button(immersiveState.isImmersive ? "Exit Immersive" : "Enter Immersive", systemImage: "visionpro") {
                    Task {
                        if immersiveState.isImmersive {
                            await dismissImmersiveSpace()
                            immersiveState.isImmersive = false
                        } else {
                            let result = await openImmersiveSpace(id: "GaussianSplatImmersive")
                            if case .opened = result {
                                immersiveState.isImmersive = true
                            }
                        }
                    }
                }
                .disabled(viewModel.loadingState != .ready)
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") {
                    showInspector.toggle()
                }
                .popover(isPresented: $showInspector) {
                    SplatDocumentInspectorView(tab: $inspectorTab)
                        .environment(viewModel)
                        .frame(width: 320, height: 480)
                }
            }
            ToolbarItem {
                Button("Settings", systemImage: "gear") {
                    showSettings = true
                }
            }
            #elseif os(iOS)
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.right") {
                    showInspector.toggle()
                }
            }
            ToolbarItem {
                Button("Settings", systemImage: "gear") {
                    showSettings = true
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
        ) { _ in
            // This line intentionally left blank.
        }
        #if !os(macOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        #endif
        .onChange(of: fileURL, initial: true) { _, newURL in
            confirmedLoad = false
            Task {
                await viewModel.load(url: newURL, contentType: document.contentType)
            }
        }
    }
}
