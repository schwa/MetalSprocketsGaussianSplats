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

// MARK: - Unified Document View

/// A unified view for displaying both single splat documents and multi-cloud scenes
struct UnifiedDocumentView: View {
    let mode: SplatContentMode

    // Single mode
    var singleDocument: SplatDocument?
    var fileURL: URL?

    // Multi mode
    @Binding var multiDocument: SplatSceneDocument?

    // MARK: - State

    @State private var singleViewModel = SplatDocumentViewModel()
    @State private var multiViewModel = SplatSceneViewModel()

    @State private var selectedCloudID: UUID?
    @State private var inspectorTab: UnifiedInspectorTab = .cloud

    // Single mode: inspector visibility
    @State private var showInspector = true

    // Multi mode: column visibility
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Single mode specific
    @State private var confirmedLoad = false
    @State private var showScreenshotSheet = false
    @State private var showExportDialog = false

    // Multi mode specific
    @State private var showAddCloudPicker = false
    @State private var showBoundingBoxes = false
    @State private var dragOffsets: [UUID: SIMD3<Float>] = [:]

    // Culling (multi mode uses state, single mode uses view model)
    @State private var cullBoundingBoxEnabled = false
    @State private var cullMinBounds: SIMD3<Float> = SIMD3(-5, -5, -5)
    @State private var cullMaxBounds: SIMD3<Float> = SIMD3(5, 5, 5)

    @Environment(\.displayScale) private var displayScale

    // MARK: - Body

    var body: some View {
        Group {
            switch mode {
            case .single:
                singleModeLayout
            case .multi:
                multiModeLayout
            }
        }
        .toolbar { toolbarContent }
        .onAppear { setupInitialState() }
    }

    private func setupInitialState() {
        inspectorTab = mode == .multi ? .scene : .cloud
    }

    // MARK: - Single Mode Layout

    @ViewBuilder
    private var singleModeLayout: some View {
        mainContent
            .inspector(isPresented: $showInspector) {
                inspectorContent
                    #if !os(visionOS)
                    .inspectorColumnWidth(min: 200, ideal: 300, max: 400)
                #endif
            }
            .focusedSceneValue(\.inspectorVisibility, $showInspector)
            .sheet(isPresented: $showScreenshotSheet) {
                ScreenshotSheet(
                    defaultWidth: Int(singleViewModel.viewSize.width * displayScale),
                    defaultHeight: Int(singleViewModel.viewSize.height * displayScale)
                )
                .environment(singleViewModel)
            }
            .fileExporter(
                isPresented: $showExportDialog,
                document: singleViewModel.convertedURL.map { PLYFileDocument(url: $0) },
                contentType: .ply,
                defaultFilename: singleViewModel.convertedURL?.deletingPathExtension().lastPathComponent
            ) { _ in
                // Export completion handled by system
            }
            .onChange(of: fileURL, initial: true) { _, newURL in
                confirmedLoad = false
                Task {
                    await singleViewModel.load(url: newURL, contentType: singleDocument?.contentType)
                }
            }
    }

    // MARK: - Multi Mode Layout

    @ViewBuilder
    private var multiModeLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            cloudListSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } content: {
            mainContent
                .navigationSplitViewColumnWidth(min: 400, ideal: 600)
        } detail: {
            inspectorContent
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .environment(multiViewModel)
        .sheet(isPresented: $showScreenshotSheet) {
            ScreenshotSheet(
                defaultWidth: Int(multiViewModel.viewSize.width * displayScale),
                defaultHeight: Int(multiViewModel.viewSize.height * displayScale)
            )
            .environment(multiViewModel)
        }
        .fileImporter(
            isPresented: $showAddCloudPicker,
            allowedContentTypes: [.ply, .spz, .antimatter15Splat, .sog],
            allowsMultipleSelection: true,
            onCompletion: handleAddClouds
        )
        .onChange(of: multiDocument?.scene.clouds, initial: true) {
            guard let doc = multiDocument else {
                return
            }
            Task {
                await multiViewModel.loadClouds(from: doc.scene)
                multiViewModel.updateCombinedBounds(for: doc.scene)
            }
        }
        .onChange(of: multiDocument?.scene.sceneTransform) {
            guard let doc = multiDocument else {
                return
            }
            multiViewModel.updateCombinedBounds(for: doc.scene)
        }
        .onChange(of: multiViewModel.loadingState) {
            guard let doc = multiDocument, multiViewModel.loadingState == .ready else {
                return
            }
            multiViewModel.updateCombinedBounds(for: doc.scene)
        }
        .onChange(of: multiViewModel.boundsUpdateCount) {
            guard let doc = multiDocument else {
                return
            }
            multiViewModel.updateCombinedBounds(for: doc.scene)
        }
    }

    // MARK: - Cloud List Sidebar (Multi Mode)

    @ViewBuilder
    private var cloudListSidebar: some View {
        List(selection: $selectedCloudID) {
            if let clouds = Binding($multiDocument)?.scene.clouds {
                ForEach(clouds) { $cloud in
                    CloudListRow(cloud: $cloud) {
                        multiDocument?.scene.clouds.removeAll { $0.id == cloud.id }
                    }
                    .tag(cloud.id)
                }
                .onDelete { indexSet in
                    multiDocument?.scene.clouds.remove(atOffsets: indexSet)
                }
                .onMove { source, destination in
                    multiDocument?.scene.clouds.move(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Clouds")
        .overlay {
            if multiDocument?.scene.clouds.isEmpty ?? true {
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

    // MARK: - Main Content (Shared)

    @ViewBuilder
    private var mainContent: some View {
        switch mode {
        case .single:
            singleModeMainContent
        case .multi:
            multiModeMainContent
        }
    }

    @ViewBuilder
    private var singleModeMainContent: some View {
        switch singleViewModel.loadingState {
        case .idle, .loading:
            ContentUnavailableView("Loading…", systemImage: "circle.dotted")
        case .converting(let status):
            conversionContent(status: status)
        case .error(let message):
            errorContent(message: message)
        case .ready:
            if needsConfirmation {
                confirmationContent
            } else if let splatCloud = singleViewModel.splatCloud {
                singleRenderView(cloud: splatCloud)
            } else {
                ContentUnavailableView("No file to render", systemImage: "questionmark")
            }
        }
    }

    @ViewBuilder
    private var multiModeMainContent: some View {
        switch multiViewModel.loadingState {
        case .idle:
            if multiDocument?.scene.clouds.isEmpty ?? true {
                ContentUnavailableView {
                    Label("Empty Scene", systemImage: "cube.transparent")
                } description: {
                    Text("Add splat clouds to start")
                }
            } else {
                multiRenderView
            }
        case .loading:
            ProgressView("Loading clouds...")
        case .ready:
            multiRenderView
        case .error(let message):
            errorContent(message: message)
        }
    }

    // MARK: - Render Views (Shared)

    @ViewBuilder
    private func singleRenderView(cloud: GPUSplatCloud<SparkSplat>) -> some View {
        let bgColor = singleViewModel.backgroundColor.resolve(in: EnvironmentValues())
        let bgColorArray: [Float] = [Float(bgColor.red), Float(bgColor.green), Float(bgColor.blue), Float(bgColor.opacity)]

        UnifiedSplatContentView(
            mode: .single,
            clouds: [cloud],
            sceneTransform: singleViewModel.modelMatrix,
            useSphericalHarmonics: singleViewModel.useSphericalHarmonics && singleViewModel.hasSphericalHarmonicsData,
            backgroundColor: bgColorArray,
            cameraMatrix: $singleViewModel.cameraMatrix,
            verticalAngleOfView: $singleViewModel.verticalAngleOfView,
            cullBoundingBox: singleViewModel.cullBoundingBox,
            showBoundingBoxes: showBoundingBoxes,
            boundingBoxInfos: singleModeBoundingBoxInfos
        )
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self, of: \.size) { singleViewModel.viewSize = $0 }
    }

    private var singleModeBoundingBoxInfos: [BoundingBoxInfo] {
        guard showBoundingBoxes, singleViewModel.boundsSize != .zero else {
            return []
        }
        let bounds = BoundingBox(
            min: singleViewModel.boundsCenter - singleViewModel.boundsSize / 2,
            max: singleViewModel.boundsCenter + singleViewModel.boundsSize / 2
        )
        return [
            BoundingBoxInfo(
                id: UUID(),
                bounds: bounds,
                modelMatrix: singleViewModel.modelMatrix,
                color: .white
            )
        ]
    }

    @ViewBuilder
    private var multiRenderView: some View {
        if let doc = multiDocument {
            let enabledCloudIDs = Set(doc.scene.clouds.filter(\.enabled).map(\.id))
            let enabledClouds: [GPUSplatCloud<SparkSplat>] = multiViewModel.loadedClouds
                .filter { enabledCloudIDs.contains($0.id) }
                .compactMap { loadedCloud in
                    if let docCloud = doc.scene.clouds.first(where: { $0.id == loadedCloud.id }) {
                        var transform = docCloud.transform
                        if let dragOffset = dragOffsets[loadedCloud.id] {
                            transform.translation += dragOffset
                        }
                        loadedCloud.cloud.modelTransform = transform.matrix
                        loadedCloud.cloud.opacity = docCloud.opacity
                    }
                    return loadedCloud.cloud
                }

            let useSH = doc.scene.renderSettings.useSphericalHarmonics && multiViewModel.allCloudsHaveSphericalHarmonics
            let cullBoundingBox: BoundingBox3D? = cullBoundingBoxEnabled
                ? BoundingBox3D(minBounds: cullMinBounds, maxBounds: cullMaxBounds)
                : nil

            UnifiedSplatContentView(
                mode: .multi,
                clouds: enabledClouds,
                sceneTransform: doc.scene.sceneTransform.matrix,
                useSphericalHarmonics: useSH,
                backgroundColor: doc.scene.renderSettings.backgroundColor,
                cameraMatrix: $multiViewModel.cameraMatrix,
                verticalAngleOfView: $multiViewModel.verticalAngleOfView,
                cullBoundingBox: cullBoundingBox,
                showBoundingBoxes: showBoundingBoxes,
                boundingBoxInfos: buildBoundingBoxInfos(),
                onDragChange: handleAxisDrag,
                onDragEnd: commitDrag
            )
            .onGeometryChange(for: CGSize.self, of: \.size) { multiViewModel.viewSize = $0 }
        }
    }

    // MARK: - Inspector (Shared)

    @ViewBuilder
    private var inspectorContent: some View {
        switch mode {
        case .single:
            UnifiedInspectorView(
                singleViewModel: singleViewModel,
                tab: $inspectorTab
            )

        case .multi:
            let selectedCloud: Binding<SplatScene.CloudReference?> = Binding(
                get: {
                    guard let selectedID = selectedCloudID,
                        let index = multiDocument?.scene.clouds.firstIndex(where: { $0.id == selectedID })
                    else {
                        return nil
                    }
                    return multiDocument?.scene.clouds[index]
                },
                set: { newValue in
                    guard let newValue,
                        let selectedID = selectedCloudID,
                        let index = multiDocument?.scene.clouds.firstIndex(where: { $0.id == selectedID })
                    else {
                        return
                    }
                    multiDocument?.scene.clouds[index] = newValue
                }
            )

            UnifiedInspectorView(
                multiViewModel: multiViewModel,
                document: $multiDocument,
                selectedCloud: selectedCloud,
                tab: $inspectorTab,
                onDeleteCloud: {
                    if let id = selectedCloudID {
                        multiDocument?.scene.clouds.removeAll { $0.id == id }
                        selectedCloudID = nil
                    }
                },
                cullBoundingBoxEnabled: $cullBoundingBoxEnabled,
                cullMinBounds: $cullMinBounds,
                cullMaxBounds: $cullMaxBounds
            )
        }
    }

    // MARK: - Toolbar (Shared)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Add Cloud (multi mode only - fundamental to multi-cloud workflow)
        if mode == .multi {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Cloud", systemImage: "plus") {
                    showAddCloudPicker = true
                }
            }
        }

        // Export PLY (single mode, image conversion only - specific workflow)
        if mode == .single, singleViewModel.isImageConversion, singleViewModel.convertedURL != nil {
            ToolbarItem(placement: .primaryAction) {
                Button("Export PLY", systemImage: "square.and.arrow.down") {
                    showExportDialog = true
                }
            }
        }

        // Screenshot (both modes)
        ToolbarItem(placement: .primaryAction) {
            Button("Screenshot", systemImage: "camera") {
                showScreenshotSheet = true
            }
        }

        // Bounding Boxes toggle (both modes)
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showBoundingBoxes) {
                Label("Bounding Boxes", systemImage: "cube")
            }
            .toggleStyle(.button)
        }
        #endif

        // Inspector toggle (both modes)
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.right") {
                withAnimation {
                    switch mode {
                    case .single:
                        showInspector.toggle()
                    case .multi:
                        if columnVisibility == .all {
                            columnVisibility = .doubleColumn
                        } else {
                            columnVisibility = .all
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helper Content Views

    @ViewBuilder
    private func conversionContent(status: String) -> some View {
        if let sourceImage = singleViewModel.sourceImage {
            ImageConversionView(sourceImage: sourceImage, statusMessage: status)
        } else {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(2)
                Text(status)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func errorContent(message: String) -> some View {
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }

    private var needsConfirmation: Bool {
        guard let descriptor = singleViewModel.descriptor else {
            return false
        }
        if singleViewModel.isImageConversion {
            return false
        }
        return descriptor.splatCount >= 1_000_000 && !confirmedLoad
    }

    @ViewBuilder
    private var confirmationContent: some View {
        ContentUnavailableView {
            Label("Large Splat Cloud", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("This file contains \(singleViewModel.descriptor!.splatCount.formatted()) splats which may take a while to load and could impact performance.")
        } actions: {
            Button("Load Anyway") {
                confirmedLoad = true
                singleViewModel.loadSplatCloud()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Multi Mode Helpers

    private func buildBoundingBoxInfos() -> [BoundingBoxInfo] {
        guard let doc = multiDocument else {
            return []
        }
        return multiViewModel.loadedClouds
            .filter { loadedCloud in
                doc.scene.clouds.first { $0.id == loadedCloud.id }?.enabled ?? false
            }
            .compactMap { loadedCloud in
                guard let bounds = loadedCloud.bounds else {
                    return nil
                }
                guard var transform = doc.scene.clouds.first(where: { $0.id == loadedCloud.id })?.transform else {
                    return nil
                }
                if let dragOffset = dragOffsets[loadedCloud.id] {
                    transform.translation += dragOffset
                }
                let modelMatrix = doc.scene.sceneTransform.matrix * transform.matrix
                return BoundingBoxInfo(id: loadedCloud.id, bounds: bounds, modelMatrix: modelMatrix, color: .white)
            }
    }

    private func handleAxisDrag(cloudID: UUID, axis: Int, screenDelta: CGSize, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4) {
        guard let doc = multiDocument,
            let cloudIndex = doc.scene.clouds.firstIndex(where: { $0.id == cloudID }),
            let loadedCloud = multiViewModel.loadedClouds.first(where: { $0.id == cloudID })
        else {
            return
        }

        let bounds = loadedCloud.bounds ?? BoundingBox(min: .zero, max: .one)
        let modelMatrix = doc.scene.sceneTransform.matrix * doc.scene.clouds[cloudIndex].transform.matrix
        let worldCenter = modelMatrix * SIMD4<Float>(bounds.center, 1)

        let axisVectors: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let axisWorld = (modelMatrix * SIMD4<Float>(axisVectors[axis], 0)).xyz
        let axisNorm = normalize(axisWorld)

        let mvp = projectionMatrix * viewMatrix
        let viewportSize = multiViewModel.viewSize

        func toScreen(_ point: SIMD4<Float>) -> CGPoint? {
            let clip = mvp * point
            guard clip.w > 0 else {
                return nil
            }
            let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            return CGPoint(
                x: CGFloat((ndc.x + 1) * 0.5 * Float(viewportSize.width)),
                y: CGFloat((1 - ndc.y) * 0.5 * Float(viewportSize.height))
            )
        }

        guard let p0 = toScreen(worldCenter),
            let p1 = toScreen(worldCenter + SIMD4<Float>(axisNorm, 0))
        else {
            return
        }

        let screenDist = hypot(p1.x - p0.x, p1.y - p0.y)
        guard screenDist > 0.001 else {
            return
        }

        let pixelsPerUnit = screenDist
        let screenMag = hypot(screenDelta.width, screenDelta.height)
        let sign: Float = (screenDelta.width * (p1.x - p0.x) + screenDelta.height * (p1.y - p0.y)) > 0 ? 1 : -1
        let worldDelta = Float(screenMag) / Float(pixelsPerUnit) * sign

        let localAxis = axisVectors[axis]
        let offset = dragOffsets[cloudID] ?? .zero
        dragOffsets[cloudID] = offset + localAxis * worldDelta

        let docTransform = doc.scene.clouds[cloudIndex].transform
        var newTransform = docTransform
        newTransform.translation += dragOffsets[cloudID]!
        loadedCloud.cloud.modelTransform = doc.scene.sceneTransform.matrix * newTransform.matrix
    }

    private func commitDrag(cloudID: UUID) {
        guard let offset = dragOffsets[cloudID], offset != .zero,
            let cloudIndex = multiDocument?.scene.clouds.firstIndex(where: { $0.id == cloudID })
        else {
            return
        }
        multiDocument?.scene.clouds[cloudIndex].transform.translation += offset
        dragOffsets[cloudID] = nil
    }

    private func handleAddClouds(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            return
        }

        var cloudRefs: [(ref: SplatScene.CloudReference, didAccess: Bool)] = []

        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            do {
                let offset = SIMD3<Float>(Float((multiDocument?.scene.clouds.count ?? 0) + cloudRefs.count) * 5.0, 0, 0)
                let transform = Transform(translation: offset)
                let cloudRef = try SplatScene.CloudReference(url: url, transform: transform)
                cloudRefs.append((cloudRef, didStartAccess))
            } catch {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }

        for (ref, _) in cloudRefs {
            multiDocument?.scene.clouds.append(ref)
        }

        for (index, url) in urls.enumerated() {
            if index < cloudRefs.count, cloudRefs[index].didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

// MARK: - Convenience Initializers

extension UnifiedDocumentView {
    /// Create view for single splat document
    init(document: SplatDocument, fileURL: URL?) {
        self.mode = .single
        self.singleDocument = document
        self.fileURL = fileURL
        self._multiDocument = .constant(nil)
    }

    /// Create view for multi-cloud scene document
    init(document: Binding<SplatSceneDocument>) {
        self.mode = .multi
        self.singleDocument = nil
        self.fileURL = nil
        self._multiDocument = Binding(
            get: { document.wrappedValue },
            set: { document.wrappedValue = $0! }
        )
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
