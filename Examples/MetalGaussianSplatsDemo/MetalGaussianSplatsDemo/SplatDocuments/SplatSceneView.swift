#if os(iOS) || os(macOS)
import GeometryLite3D
import SwiftUI
import UniformTypeIdentifiers
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd

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
                CloudListRow(cloud: $cloud)
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
                // Count enabled clouds from document (source of truth for enabled state)
                let enabledCount = document.scene.clouds.filter(\.enabled).count
                
                // Placeholder for actual rendering
                ZStack {
                    Color.black
                    VStack {
                        Text("Multi-cloud rendering")
                            .font(.headline)
                        Text("\(viewModel.loadedClouds.count) cloud(s) loaded")
                        Text("\(enabledCount) enabled")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
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
            viewModel: viewModel
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
                    let transform = simd_float4x4(translation: offset)
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
        }
    }
}

// MARK: - Scene Inspector Tab

enum SceneInspectorTab: String, CaseIterable {
    case cloud = "Cloud"
    case scene = "Scene"
    case render = "Render"
}

// MARK: - Inspector Content

struct SplatSceneInspectorView: View {
    @Binding var tab: SceneInspectorTab
    @Binding var cloud: SplatScene.CloudReference?
    @Binding var document: SplatSceneDocument
    let loadedCloud: SplatSceneViewModel.LoadedCloud?
    let viewModel: SplatSceneViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker at top
            Picker("Tab", selection: $tab) {
                ForEach(SceneInspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            // Content
            Group {
                switch tab {
                case .cloud:
                    if var cloudBinding = cloud {
                        Form {
                            CloudInspectorContent(cloud: Binding(
                                get: { cloudBinding },
                                set: { cloudBinding = $0; cloud = $0 }
                            ), loadedCloud: loadedCloud)
                        }
                        .formStyle(.grouped)
                    } else {
                        ContentUnavailableView("No Selection", systemImage: "cube.transparent", description: Text("Select a cloud to view its details"))
                    }
                case .scene:
                    Form {
                        SceneInspectorContent(document: $document)
                    }
                    .formStyle(.grouped)
                case .render:
                    Form {
                        RenderInspectorContent(
                            renderSettings: $document.scene.renderSettings,
                            allCloudsHaveSH: viewModel.allCloudsHaveSphericalHarmonics
                        )
                    }
                    .formStyle(.grouped)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CloudInspectorContent: View {
    @Binding var cloud: SplatScene.CloudReference
    let loadedCloud: SplatSceneViewModel.LoadedCloud?

    var body: some View {
        Section("Cloud") {
            TextField("Name", text: Binding(
                get: { cloud.displayName ?? "" },
                set: { cloud.displayName = $0.isEmpty ? nil : $0 }
            ))

            Toggle("Enabled", isOn: $cloud.enabled)
        }

        Section("Transform") {
            TransformEditor(transform: $cloud.transform)
        }

        if let loaded = loadedCloud {
            SplatCloudInfoSections(descriptor: loaded.descriptor)
        }
    }
}

struct SceneInspectorContent: View {
    @Binding var document: SplatSceneDocument

    var body: some View {
        Section("Scene") {
            LabeledContent("Clouds", value: "\(document.scene.clouds.count)")
            LabeledContent("Enabled", value: "\(document.scene.clouds.filter(\.enabled).count)")
        }

        Section("Scene Transform") {
            TransformEditor(transform: $document.scene.sceneTransform)
        }
    }
}

struct RenderInspectorContent: View {
    @Binding var renderSettings: SplatScene.RenderSettings
    let allCloudsHaveSH: Bool

    var body: some View {
        Section("Spherical Harmonics") {
            Toggle("Use Spherical Harmonics", isOn: $renderSettings.useSphericalHarmonics)
                .disabled(!allCloudsHaveSH)

            if !allCloudsHaveSH {
                Label("Not all clouds have SH data", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Transform Editor

struct TransformEditor: View {
    @Binding var transform: simd_float4x4

    private var position: Binding<SIMD3<Float>> {
        Binding(
            get: {
                SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            },
            set: { newValue in
                transform.columns.3 = SIMD4<Float>(newValue, 1)
            }
        )
    }

    var body: some View {
        LabeledContent("Position") {
            HStack {
                FloatField("X", value: position.x)
                FloatField("Y", value: position.y)
                FloatField("Z", value: position.z)
            }
        }
        // TODO: Add rotation and scale editors
    }
}

struct FloatField: View {
    let label: String
    @Binding var value: Float

    init(_ label: String, value: Binding<Float>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("", value: $value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        }
    }
}

// MARK: - View Model

@Observable
final class SplatSceneViewModel {
    enum LoadingState {
        case idle
        case loading
        case ready
        case error(String)
    }

    var loadingState: LoadingState = .idle
    var loadedClouds: [LoadedCloud] = []
    var viewSize: CGSize = .zero

    // Camera
    var cameraMatrix: simd_float4x4 = .init(translation: [0, 0, 10])
    var sceneTransform: simd_float4x4 = simd_float4x4(xRotation: .radians(.pi))
    var verticalAngleOfView: Double = 90

    private var resourceAccess = ScopedResourceAccess()
    
    /// Track which cloud IDs we've loaded to avoid reloading on property-only changes
    private var loadedCloudIDs: Set<UUID> = []

    struct LoadedCloud: Identifiable {
        let id: UUID
        let displayName: String
        let cloud: GPUSplatCloud<SparkSplat>
        let descriptor: SplatCloudDescriptor
    }

    /// Whether all loaded clouds have spherical harmonics data
    var allCloudsHaveSphericalHarmonics: Bool {
        guard !loadedClouds.isEmpty else { return false }
        return loadedClouds.allSatisfy { $0.descriptor.hasSphericalHarmonics }
    }

    /// Check if we need to reload (structural change) vs just update properties
    func needsReload(for scene: SplatScene) -> Bool {
        let sceneCloudIDs = Set(scene.clouds.map(\.id))
        return sceneCloudIDs != loadedCloudIDs
    }

    @MainActor
    func loadClouds(from scene: SplatScene) async {
        // Only reload if structural change (add/remove clouds)
        guard needsReload(for: scene) else {
            return
        }
        
        if scene.clouds.isEmpty {
            loadingState = .idle
            loadedClouds = []
            loadedCloudIDs = []
            return
        }

        loadingState = .loading

        // Stop accessing previous resources
        resourceAccess.stopAccessing()

        do {
            let resolved = try resourceAccess.startAccessing(scene: scene)
            var loaded: [LoadedCloud] = []

            for resolvedCloud in resolved {
                do {
                    let descriptor = try SplatCloudDescriptor(url: resolvedCloud.url)
                    let gpuCloud: GPUSplatCloud<SparkSplat> = try descriptor.loadGPUSplatCloud(
                        modelTransform: resolvedCloud.transform
                    )
                    loaded.append(LoadedCloud(
                        id: resolvedCloud.id,
                        displayName: resolvedCloud.displayName ?? resolvedCloud.url.lastPathComponent,
                        cloud: gpuCloud,
                        descriptor: descriptor
                    ))
                } catch {
                    print("Failed to load cloud \(resolvedCloud.url): \(error)")
                }
            }

            loadedClouds = loaded
            loadedCloudIDs = Set(loaded.map(\.id))
            sceneTransform = scene.sceneTransform

            if let camera = scene.camera {
                cameraMatrix = camera.matrix
                verticalAngleOfView = camera.verticalAngleOfView
            }

            loadingState = loaded.isEmpty ? .idle : .ready
        } catch {
            loadingState = .error("Failed to load clouds: \(error.localizedDescription)")
        }
    }

    deinit {
        resourceAccess.stopAccessing()
    }
}
#endif
