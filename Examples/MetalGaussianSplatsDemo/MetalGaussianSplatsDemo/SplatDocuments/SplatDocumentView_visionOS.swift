#if os(visionOS)
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import SwiftUI

/// A visionOS-specific view for displaying a Gaussian Splat document with immersive support
/// Uses the unified content view infrastructure shared with multi-cloud scenes
struct SplatDocumentView: View {
    let document: SplatDocument
    let fileURL: URL?

    @State private var viewModel = SplatDocumentViewModel()
    @State private var showInspector = false
    @State private var inspectorTab: UnifiedInspectorTab = .cloud
    @State private var confirmedLoad = false
    @State private var showScreenshotSheet = false
    @State private var showExportDialog = false
    @State private var showSettings = false

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersiveState = ImmersiveState.shared

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
        .focusedSceneValue(\.inspectorVisibility, $showInspector)
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
        ) { _ in
            // This line intentionally left blank.
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .onChange(of: fileURL, initial: true) { _, newURL in
            confirmedLoad = false
            Task {
                if immersiveState.isImmersive {
                    await dismissImmersiveSpace()
                    immersiveState.isImmersive = false
                }
                immersiveState.translation = .zero
                immersiveState.scale = 1.0
                await viewModel.load(url: newURL, contentType: document.contentType)
            }
        }
        .onChange(of: viewModel.modelMatrix, initial: true) {
            ImmersiveState.shared.modelMatrix = viewModel.modelMatrix
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let splatCloud = viewModel.splatCloud, !needsConfirmation {
            if immersiveState.isImmersive {
                ImmersiveModeControlsView {
                    Task {
                        await dismissImmersiveSpace()
                        immersiveState.isImmersive = false
                    }
                }
                .environment(viewModel)
            } else {
                let bgColor = viewModel.backgroundColor.resolve(in: EnvironmentValues())
                let bgColorArray: [Float] = [
                    Float(bgColor.red),
                    Float(bgColor.green),
                    Float(bgColor.blue),
                    Float(bgColor.opacity)
                ]

                UnifiedSplatContentView(
                    mode: .single,
                    clouds: [splatCloud],
                    sceneTransform: viewModel.modelMatrix,
                    useSphericalHarmonics: viewModel.useSphericalHarmonics && viewModel.hasSphericalHarmonicsData,
                    backgroundColor: bgColorArray,
                    cameraMatrix: $viewModel.cameraMatrix,
                    verticalAngleOfView: $viewModel.verticalAngleOfView,
                    cullBoundingBox: viewModel.cullBoundingBox
                )
                .ignoresSafeArea()
            }
        } else if needsConfirmation {
            ContentUnavailableView {
                Label("Large Splat Cloud", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text("This file contains \(viewModel.descriptor!.splatCount.formatted()) splats which may take a while to load and could impact performance.")
            } actions: {
                Button("Load Anyway") {
                    confirmedLoad = true
                    viewModel.loadSplatCloud()
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
        ToolbarItem {
            Button(immersiveState.isImmersive ? "Exit Immersive" : "Enter Immersive", systemImage: "visionpro") {
                Task {
                    if immersiveState.isImmersive {
                        await dismissImmersiveSpace()
                        immersiveState.isImmersive = false
                    } else {
                        showInspector = false
                        let result = await openImmersiveSpace(id: "GaussianSplatImmersive")
                        switch result {
                        case .opened:
                            immersiveState.isImmersive = true
                        case .userCancelled, .error:
                            immersiveState.isImmersive = false
                        @unknown default:
                            immersiveState.isImmersive = false
                        }
                    }
                }
            }
            .disabled(viewModel.loadingState != .ready)
        }
        ToolbarItem {
            Button("Inspector", systemImage: "slider.horizontal.3") {
                showInspector.toggle()
            }
            .disabled(immersiveState.isImmersive)
            .popover(isPresented: $showInspector) {
                UnifiedInspectorView(
                    singleViewModel: viewModel,
                    tab: $inspectorTab
                )
                .frame(width: 420, height: 520)
            }
        }
        ToolbarItem {
            Button("Settings", systemImage: "gear") {
                showSettings = true
            }
        }
    }
}
#endif
