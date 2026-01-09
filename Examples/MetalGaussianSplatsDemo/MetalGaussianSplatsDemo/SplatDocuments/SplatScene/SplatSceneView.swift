#if os(iOS) || os(macOS)
import GeometryLite3D
import Interaction3D
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
import simd
import SwiftUI
import UniformTypeIdentifiers

/// View for editing and rendering a splat scene with multiple clouds
struct SplatSceneView: View {
    @Binding var document: SplatSceneDocument

    @State private var viewModel = SplatSceneViewModel()
    @State private var selectedCloudID: UUID?
    @State private var showAddCloudPicker = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorTab: SceneInspectorTab = .cloud

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            cloudListSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } content: {
            renderContent
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            inspectorContent
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showAddCloudPicker,
            allowedContentTypes: [.ply, .spz, .antimatter15Splat, .sog],
            allowsMultipleSelection: true
        ) { result in
            handleAddClouds(result)
        }
        .onChange(of: document.scene.clouds, initial: true) {
            Task {
                await viewModel.loadClouds(from: document.scene)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var cloudListSidebar: some View {
        List(selection: $selectedCloudID) {
            ForEach($document.scene.clouds) { $cloud in
                CloudListRow(cloud: $cloud) {
                    document.scene.clouds.removeAll { $0.id == cloud.id }
                }
                .tag(cloud.id)
            }
            .onDelete { indexSet in
                document.scene.clouds.remove(atOffsets: indexSet)
            }
            .onMove { source, destination in
                document.scene.clouds.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Clouds")
        .overlay {
            if document.scene.clouds.isEmpty {
                ContentUnavailableView {
                    Label("No Clouds", systemImage: "cube.transparent")
                } description: {
                    Text("Add splat clouds to your scene")
                } actions: {
                    Button("Add Cloud") {
                        showAddCloudPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Detail/Render Content

    @ViewBuilder
    private var renderContent: some View {
        switch viewModel.loadingState {
        case .idle:
            ContentUnavailableView {
                Label("Empty Scene", systemImage: "cube.transparent")
            } description: {
                Text("Add splat clouds to start")
            }
        case .loading:
            ProgressView("Loading clouds...")
        case .ready:
            if viewModel.loadedClouds.isEmpty {
                ContentUnavailableView("No clouds loaded", systemImage: "cube.transparent")
            } else {
                // Get enabled cloud IDs from document and sync transforms
                let enabledCloudIDs = Set(document.scene.clouds.filter(\.enabled).map(\.id))
                let enabledClouds: [GPUSplatCloud<SparkSplat>] = viewModel.loadedClouds
                    .filter { enabledCloudIDs.contains($0.id) }
                    .compactMap { loadedCloud in
                        // Get current transform from document
                        if let docCloud = document.scene.clouds.first(where: { $0.id == loadedCloud.id }) {
                            loadedCloud.cloud.modelTransform = docCloud.transform.matrix
                        }
                        return loadedCloud.cloud
                    }
                
                if enabledClouds.isEmpty {
                    // All clouds are hidden
                    ZStack {
                        Color.black
                        VStack {
                            Image(systemName: "eye.slash")
                                .font(.largeTitle)
                            Text("All clouds hidden")
                                .font(.headline)
                            Text("Enable clouds in the sidebar to view")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.white)
                    }
                } else {
                    // Determine if we should use SH
                    let useSH = document.scene.renderSettings.useSphericalHarmonics && viewModel.allCloudsHaveSphericalHarmonics
                    
                    MultiCloudRenderView(
                        clouds: enabledClouds,
                        cameraMatrix: $viewModel.cameraMatrix,
                        sceneTransform: document.scene.sceneTransform.matrix,
                        verticalAngleOfView: $viewModel.verticalAngleOfView,
                        useSphericalHarmonics: useSH
                    )
                }
            }
        case .error(let message):
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorContent: some View {
        let selectedCloud: Binding<SplatScene.CloudReference?> = Binding(
            get: {
                guard let selectedID = selectedCloudID,
                      let index = document.scene.clouds.firstIndex(where: { $0.id == selectedID }) else {
                    return nil
                }
                return document.scene.clouds[index]
            },
            set: { newValue in
                guard let newValue,
                      let selectedID = selectedCloudID,
                      let index = document.scene.clouds.firstIndex(where: { $0.id == selectedID }) else {
                    return
                }
                document.scene.clouds[index] = newValue
            }
        )
        
        SplatSceneInspectorView(
            tab: $inspectorTab,
            cloud: selectedCloud,
            document: $document,
            loadedCloud: selectedCloudID.flatMap { id in viewModel.loadedClouds.first { $0.id == id } },
            viewModel: viewModel,
            onDeleteCloud: {
                if let id = selectedCloudID {
                    document.scene.clouds.removeAll { $0.id == id }
                    selectedCloudID = nil
                }
            }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Add Cloud", systemImage: "plus") {
                showAddCloudPicker = true
            }
        }
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.right") {
                withAnimation {
                    if columnVisibility == .all {
                        columnVisibility = .doubleColumn
                    } else {
                        columnVisibility = .all
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Add Clouds

    private func handleAddClouds(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            print("handleAddClouds: received \(urls.count) URLs")

            // First, start accessing ALL URLs and create all bookmarks while we have access
            var cloudRefs: [(ref: SplatScene.CloudReference, didAccess: Bool)] = []

            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                print("  URL: \(url.lastPathComponent), didStartAccess: \(didStartAccess)")

                do {
                    let offset = calculateNextCloudOffset(additionalCount: cloudRefs.count)
                    let transform = Transform(translation: offset)
                    let cloudRef = try SplatScene.CloudReference(url: url, transform: transform)
                    cloudRefs.append((cloudRef, didStartAccess))
                    print("  Created bookmark for: \(cloudRef.displayName ?? url.lastPathComponent)")
                } catch {
                    print("  Failed to create bookmark for \(url): \(error)")
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }

            // Now append all successfully created refs to the document
            for (ref, _) in cloudRefs {
                document.scene.clouds.append(ref)
                print("  Added cloud: \(ref.displayName ?? "unknown"), total: \(document.scene.clouds.count)")
            }

            // Stop accessing all URLs
            for (index, url) in urls.enumerated() {
                if index < cloudRefs.count && cloudRefs[index].didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

        case .failure(let error):
            print("Failed to pick files: \(error)")
        }
    }

    /// Calculate where to place the next cloud (to the right of existing clouds)
    private func calculateNextCloudOffset(additionalCount: Int = 0) -> SIMD3<Float> {
        // For now, just offset each cloud by 5 units in X
        // TODO: Use actual bounding boxes
        let cloudCount = document.scene.clouds.count + additionalCount
        return SIMD3<Float>(Float(cloudCount) * 5.0, 0, 0)
    }
}

// MARK: - Cloud List Row

struct CloudListRow: View {
    @Binding var cloud: SplatScene.CloudReference
    var onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: $cloud.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Text(cloud.displayName ?? "Unknown")
                .lineLimit(1)
                .foregroundStyle(cloud.enabled ? .primary : .secondary)
        }
        .contextMenu {
            Toggle("Enabled", isOn: $cloud.enabled)
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
#endif
