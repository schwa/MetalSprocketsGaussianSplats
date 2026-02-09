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
    @State private var showBoundingBoxes = false
    @State private var viewportSize: CGSize = .zero
    @State private var dragOffsets: [UUID: SIMD3<Float>] = [:] // Accumulated drag offset per cloud

    // Culling bounding box
    @State private var cullBoundingBoxEnabled = false
    @State private var cullMinBounds: SIMD3<Float> = SIMD3(-5, -5, -5)
    @State private var cullMaxBounds: SIMD3<Float> = SIMD3(5, 5, 5)

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
        .environment(viewModel)
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
            if document.scene.clouds.isEmpty {
                ContentUnavailableView {
                    Label("Empty Scene", systemImage: "cube.transparent")
                } description: {
                    Text("Add splat clouds to start")
                }
            } else {
                // Have clouds in document but not loaded yet (all disabled case on fresh load)
                renderView
            }
        case .loading:
            ProgressView("Loading clouds...")
        case .ready:
            renderView
        case .error(let message):
            ContentUnavailableView {
                Label("Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    @ViewBuilder
    private var renderView: some View {
        @Bindable var viewModel = viewModel
        
        // Get enabled cloud IDs from document and sync transforms
        let enabledCloudIDs = Set(document.scene.clouds.filter(\.enabled).map(\.id))
        let enabledClouds: [GPUSplatCloud<SparkSplat>] = viewModel.loadedClouds
            .filter { enabledCloudIDs.contains($0.id) }
            .compactMap { loadedCloud in
                // Get current transform and opacity from document + any active drag offset
                if let docCloud = document.scene.clouds.first(where: { $0.id == loadedCloud.id }) {
                    var transform = docCloud.transform
                    if let dragOffset = dragOffsets[loadedCloud.id] {
                        transform.translation += dragOffset
                    }
                    loadedCloud.cloud.modelTransform = transform.matrix
                    loadedCloud.cloud.opacity = docCloud.opacity
                }
                return loadedCloud.cloud
            }
        
        // Determine if we should use SH
        let useSH = document.scene.renderSettings.useSphericalHarmonics && viewModel.allCloudsHaveSphericalHarmonics
        
        // Build culling bounding box if enabled
        let cullBoundingBox: BoundingBox3D? = cullBoundingBoxEnabled
            ? BoundingBox3D(minBounds: cullMinBounds, maxBounds: cullMaxBounds)
            : nil

        ZStack {
            MultiCloudRenderView(
                clouds: enabledClouds,
                cameraMatrix: $viewModel.cameraMatrix,
                sceneTransform: document.scene.sceneTransform.matrix,
                verticalAngleOfView: $viewModel.verticalAngleOfView,
                useSphericalHarmonics: useSH,
                backgroundColor: document.scene.renderSettings.backgroundColor,
                cullBoundingBox: cullBoundingBox
            )
            
            if showBoundingBoxes {
                boundingBoxOverlay
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            viewportSize = newSize
        }
        .overlay {
            if enabledClouds.isEmpty {
                ContentUnavailableView {
                    Label("All Clouds Hidden", systemImage: "eye.slash")
                } description: {
                    Text("Enable clouds in the sidebar to view")
                }
                .background(.ultraThinMaterial)
            }
        }
    }
    
    @ViewBuilder
    private var boundingBoxOverlay: some View {
        // Create projection using same approach as MultiCloudRenderView
        let projection = PerspectiveProjection(
            verticalAngleOfView: .degrees(Float(viewModel.verticalAngleOfView)),
            depthMode: .standard(zClip: 0.01 ... 1000)
        )
        let projectionMatrix = projection.projectionMatrix(for: viewportSize)
        
        // View matrix is inverse of camera matrix
        let viewMatrix = viewModel.cameraMatrix.inverse
        
        // Build bounding box info for enabled clouds
        let boxes: [BoundingBoxInfo] = viewModel.loadedClouds
            .filter { loadedCloud in
                document.scene.clouds.first { $0.id == loadedCloud.id }?.enabled ?? false
            }
            .compactMap { loadedCloud in
                guard let bounds = loadedCloud.bounds else { return nil }
                guard var transform = document.scene.clouds.first(where: { $0.id == loadedCloud.id })?.transform else { return nil }
                // Apply drag offset if active
                if let dragOffset = dragOffsets[loadedCloud.id] {
                    transform.translation += dragOffset
                }
                let modelMatrix = document.scene.sceneTransform.matrix * transform.matrix
                return BoundingBoxInfo(
                    id: loadedCloud.id,
                    bounds: bounds,
                    modelMatrix: modelMatrix,
                    color: .white
                )
            }
        
        ZStack {
            // Interactive faces (below wireframe)
            BoundingBoxFaceInteraction(
                boundingBoxes: boxes,
                viewMatrix: viewMatrix,
                projectionMatrix: projectionMatrix,
                viewportSize: viewportSize,
                onDragChange: { cloudID, axis, screenDelta in
                    handleAxisDrag(cloudID: cloudID, axis: axis, screenDelta: screenDelta, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix)
                },
                onDragEnd: { cloudID in
                    commitDrag(cloudID: cloudID)
                }
            )
            
            // Wireframe (on top)
            BoundingBoxWireframe(
                boundingBoxes: boxes,
                viewMatrix: viewMatrix,
                projectionMatrix: projectionMatrix,
                viewportSize: viewportSize
            )
        }
    }
    
    private func handleAxisDrag(cloudID: UUID, axis: Int, screenDelta: CGSize, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4) {
        guard let cloudIndex = document.scene.clouds.firstIndex(where: { $0.id == cloudID }) else { return }
        guard let loadedCloud = viewModel.loadedClouds.first(where: { $0.id == cloudID }) else { return }
        
        // Get the cloud's center in world space
        let bounds = loadedCloud.bounds ?? BoundingBox(min: .zero, max: .one)
        let modelMatrix = document.scene.sceneTransform.matrix * document.scene.clouds[cloudIndex].transform.matrix
        let worldCenter = modelMatrix * SIMD4<Float>(bounds.center, 1)
        
        // Compute pixels per world unit at this depth
        let axisVectors: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(0,1,0), SIMD3(0,0,1)]
        let axisWorld = (modelMatrix * SIMD4<Float>(axisVectors[axis], 0)).xyz
        let axisNorm = normalize(axisWorld)
        
        // Project center and center+axis to screen
        let mvp = projectionMatrix * viewMatrix
        func toScreen(_ p: SIMD4<Float>) -> CGPoint? {
            let clip = mvp * p
            guard clip.w > 0 else { return nil }
            let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            return CGPoint(
                x: CGFloat((ndc.x + 1) * 0.5 * Float(viewportSize.width)),
                y: CGFloat((1 - ndc.y) * 0.5 * Float(viewportSize.height))
            )
        }
        
        guard let p0 = toScreen(worldCenter),
              let p1 = toScreen(worldCenter + SIMD4<Float>(axisNorm, 0)) else { return }
        
        let screenDist = hypot(p1.x - p0.x, p1.y - p0.y)
        guard screenDist > 0.001 else { return }
        
        // pixels per world unit
        let pixelsPerUnit = screenDist
        
        // Convert screen delta magnitude to world units
        let screenMag = hypot(screenDelta.width, screenDelta.height)
        let sign: Float = (screenDelta.width * (p1.x - p0.x) + screenDelta.height * (p1.y - p0.y)) > 0 ? 1 : -1
        let worldDelta = Float(screenMag) / Float(pixelsPerUnit) * sign
        
        // Accumulate drag offset (don't update document yet)
        let localAxis = axisVectors[axis]
        let offset = dragOffsets[cloudID] ?? .zero
        dragOffsets[cloudID] = offset + localAxis * worldDelta
        
        // Update GPU cloud's transform directly (doesn't trigger SwiftUI)
        let docTransform = document.scene.clouds[cloudIndex].transform
        var newTransform = docTransform
        newTransform.translation += dragOffsets[cloudID]!
        loadedCloud.cloud.modelTransform = document.scene.sceneTransform.matrix * newTransform.matrix
    }
    
    private func commitDrag(cloudID: UUID) {
        guard let offset = dragOffsets[cloudID], offset != .zero else { return }
        guard let cloudIndex = document.scene.clouds.firstIndex(where: { $0.id == cloudID }) else { return }
        
        // Commit accumulated offset to document
        document.scene.clouds[cloudIndex].transform.translation += offset
        dragOffsets[cloudID] = nil
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
            onDeleteCloud: {
                if let id = selectedCloudID {
                    document.scene.clouds.removeAll { $0.id == id }
                    selectedCloudID = nil
                }
            },
            cullBoundingBoxEnabled: $cullBoundingBoxEnabled,
            cullMinBounds: $cullMinBounds,
            cullMaxBounds: $cullMaxBounds
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
            Toggle(isOn: $showBoundingBoxes) {
                Label("Bounding Boxes", systemImage: "cube")
            }
            .toggleStyle(.button)
        }
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
