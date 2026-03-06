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

// MARK: - DebugCloudIndexParams Helper

extension DebugCloudIndexParams {
    /// Create params with custom cloud colors
    /// - Parameters:
    ///   - cloudCount: Number of clouds
    ///   - colors: Array of colors for each cloud (up to 16). Remaining slots filled with white.
    static func withColors(cloudCount: UInt32, colors: [SIMD3<Float>]) -> DebugCloudIndexParams {
        // Swift bridges C arrays as tuples, so we need to create it manually
        var params = DebugCloudIndexParams()
        params.cloudCount = cloudCount

        // Fill colors into the tuple (up to 16)
        withUnsafeMutablePointer(to: &params.cloudColors) { ptr in
            let colorPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: SIMD3<Float>.self)
            for i in 0..<16 {
                if i < colors.count {
                    colorPtr[i] = colors[i]
                } else {
                    colorPtr[i] = SIMD3<Float>(1, 1, 1) // Default to white
                }
            }
        }
        return params
    }
}

// MARK: - Document Content View

/// A unified view for displaying both single splat documents and multi-cloud scenes
struct SplatDocumentContentView: View {
    let mode: SplatContentMode

    // Single mode
    var singleDocument: SplatDocument?
    var fileURL: URL?

    // Multi mode
    @Binding var multiDocument: SplatSceneDocument?

    // MARK: - State

    @State private var viewModel: SplatViewModel

    @State private var selectedCloudID: UUID?
    @State private var inspectorTab: InspectorTab = .cloud

    // Inspector visibility (both modes)
    @SceneStorage("showInspector") private var showInspector = true

    // Multi mode: sidebar visibility
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    // Single mode specific
    @State private var confirmedLoad = false
    @State private var showScreenshotSheet = false
    @State private var showExportDialog = false

    // Multi mode specific
    @State private var showAddCloudPicker = false
    @State private var dragOffsets: [UUID: SIMD3<Float>] = [:]

    @Environment(\.displayScale) private var displayScale

    // MARK: - Initialization

    private init(mode: SplatContentMode, singleDocument: SplatDocument?, fileURL: URL?, multiDocument: Binding<SplatSceneDocument?>) {
        self.mode = mode
        self.singleDocument = singleDocument
        self.fileURL = fileURL
        self._multiDocument = multiDocument
        self._viewModel = State(initialValue: SplatViewModel(mode: mode == .single ? .single : .multi))
    }

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

    // MARK: - Prepared Data for Screenshot

    /// Returns the cloud infos (descriptors + transforms) and scene transform for screenshot rendering
    private var screenshotData: (cloudInfos: [(descriptor: SplatCloudDescriptor, modelTransform: simd_float4x4)], sceneTransform: simd_float4x4) {
        switch mode {
        case .single:
            let infos = viewModel.loadedClouds.map { loadedCloud in
                (descriptor: loadedCloud.descriptor, modelTransform: simd_float4x4.identity)
            }
            return (infos, viewModel.sceneTransform)

        case .multi:
            guard let doc = multiDocument else {
                return ([], .identity)
            }
            let enabledCloudIDs = Set(doc.scene.clouds.filter(\.enabled).map(\.id))
            let infos: [(descriptor: SplatCloudDescriptor, modelTransform: simd_float4x4)] = viewModel.loadedClouds
                .filter { enabledCloudIDs.contains($0.id) }
                .compactMap { loadedCloud in
                    guard let docCloud = doc.scene.clouds.first(where: { $0.id == loadedCloud.id }) else {
                        return nil
                    }
                    var transform = docCloud.transform
                    if let dragOffset = dragOffsets[loadedCloud.id] {
                        transform.translation += dragOffset
                    }
                    return (descriptor: loadedCloud.descriptor, modelTransform: transform.matrix)
                }
            return (infos, doc.scene.sceneTransform.matrix)
        }
    }

    // MARK: - Single Mode Layout

    @ViewBuilder
    private var singleModeLayout: some View {
        mainContent
            .inspector(isPresented: $showInspector) {
                LazyView {
                    inspectorContent
                }
                #if !os(visionOS)
                .inspectorColumnWidth(min: 200, ideal: 300, max: 400)
                #endif
            }
            .focusedSceneValue(\.inspectorVisibility, $showInspector)
            .sheet(isPresented: $showScreenshotSheet) {
                let data = screenshotData
                ScreenshotSheet(
                    cloudInfos: data.cloudInfos,
                    sceneTransform: data.sceneTransform,
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
                // Export completion handled by system
            }
            .onChange(of: fileURL, initial: true) { _, newURL in
                confirmedLoad = false
                Task {
                    await viewModel.load(url: newURL, contentType: singleDocument?.contentType)
                }
            }
            .environment(viewModel)
    }

    // MARK: - Multi Mode Layout

    @ViewBuilder
    private var multiModeLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LazyView {
                cloudListSidebar
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            mainContent
                .inspector(isPresented: $showInspector) {
                    LazyView {
                        inspectorContent
                    }
                    #if !os(visionOS)
                    .inspectorColumnWidth(min: 200, ideal: 300, max: 400)
                    #endif
                }
        }
        .focusedSceneValue(\.inspectorVisibility, $showInspector)
        .environment(viewModel)
        .sheet(isPresented: $showScreenshotSheet) {
            let data = screenshotData
            ScreenshotSheet(
                cloudInfos: data.cloudInfos,
                sceneTransform: data.sceneTransform,
                defaultWidth: Int(viewModel.viewSize.width * displayScale),
                defaultHeight: Int(viewModel.viewSize.height * displayScale)
            )
            .environment(viewModel)
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
                viewModel.loadClouds(from: doc.scene)
                viewModel.updateCombinedBounds(for: doc.scene)
            }
            // Ensure there's always a selection if clouds exist
            ensureSelection()
        }
        .onChange(of: multiDocument?.scene.sceneTransform) {
            guard let doc = multiDocument else {
                return
            }
            viewModel.updateCombinedBounds(for: doc.scene)
        }
        .onChange(of: viewModel.loadingState) {
            guard let doc = multiDocument, viewModel.loadingState == .ready else {
                return
            }
            viewModel.updateCombinedBounds(for: doc.scene)
        }
        .onChange(of: viewModel.boundsUpdateCount) {
            guard let doc = multiDocument else {
                return
            }
            viewModel.updateCombinedBounds(for: doc.scene)
        }
        // Sync camera state back to document
        .onChange(of: viewModel.cameraMatrix) {
            guard mode == .multi else {
                return
            }
            multiDocument?.scene.camera = SplatScene.CameraState(
                matrix: viewModel.cameraMatrix,
                verticalAngleOfView: viewModel.verticalAngleOfView,
                mode: viewModel.cameraMode.rawValue.lowercased()
            )
        }
        .onChange(of: viewModel.verticalAngleOfView) {
            guard mode == .multi else {
                return
            }
            multiDocument?.scene.camera = SplatScene.CameraState(
                matrix: viewModel.cameraMatrix,
                verticalAngleOfView: viewModel.verticalAngleOfView,
                mode: viewModel.cameraMode.rawValue.lowercased()
            )
        }
        .onChange(of: viewModel.cameraMode) {
            guard mode == .multi else {
                return
            }
            multiDocument?.scene.camera = SplatScene.CameraState(
                matrix: viewModel.cameraMatrix,
                verticalAngleOfView: viewModel.verticalAngleOfView,
                mode: viewModel.cameraMode.rawValue.lowercased()
            )
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
                    .onTapGesture(count: 2) {
                        // Double-click to teleport to cloud center
                        if let loadedCloud = viewModel.loadedClouds.first(where: { $0.id == cloud.id }),
                            let bounds = loadedCloud.bounds {
                            let localCenter = bounds.center
                            let worldCenter = (cloud.transform.matrix * SIMD4<Float>(localCenter, 1)).xyz
                            viewModel.cameraMatrix = simd_float4x4(translation: worldCenter)
                        }
                    }
                    .contextMenu {
                        Button("Exclusive") {
                            // Disable all other clouds, enable this one
                            for i in multiDocument!.scene.clouds.indices {
                                multiDocument!.scene.clouds[i].enabled = (multiDocument!.scene.clouds[i].id == cloud.id)
                            }
                        }
                        Button("Enable All") {
                            for i in multiDocument!.scene.clouds.indices {
                                multiDocument!.scene.clouds[i].enabled = true
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            multiDocument?.scene.clouds.removeAll { $0.id == cloud.id }
                        }
                    }
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
        .safeAreaInset(edge: .bottom) {
            Button {
                showAddCloudPicker = true
            } label: {
                Label("Add Cloud", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding()
        }
        .overlay {
            if multiDocument?.scene.clouds.isEmpty ?? true {
                ContentUnavailableView {
                    Label("No Clouds", systemImage: "cube.transparent")
                } description: {
                    Text("Add splat clouds to your scene")
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
        switch viewModel.loadingState {
        case .idle, .loading:
            ContentUnavailableView("Loading…", systemImage: "circle.dotted")
        case .converting(let status):
            conversionContent(status: status)
        case .error(let message):
            errorContent(message: message)
        case .ready:
            if needsConfirmation {
                confirmationContent
            } else if let splatCloud = viewModel.splatCloud {
                singleRenderView(cloud: splatCloud)
            } else {
                ContentUnavailableView("No file to render", systemImage: "questionmark")
            }
        }
    }

    @ViewBuilder
    private var multiModeMainContent: some View {
        switch viewModel.loadingState {
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
        case .converting:
            ProgressView("Converting...")
        case .error(let message):
            errorContent(message: message)
        }
    }

    // MARK: - Render Views (Shared)

    @ViewBuilder
    private func singleRenderView(cloud: GPUSplatCloud<SparkSplat>) -> some View {
        if let sortManager = viewModel.sortManager {
            SplatRenderView(
                mode: .single,
                clouds: [cloud],
                sceneTransform: viewModel.sceneTransform,
                useSphericalHarmonics: viewModel.effectiveUseSphericalHarmonics,
                backgroundColor: viewModel.backgroundColorArray,
                cameraMatrix: $viewModel.cameraMatrix,
                verticalAngleOfView: $viewModel.verticalAngleOfView,
                cullBoundingBox: viewModel.cullBoundingBox,
                showBoundingBoxes: viewModel.showBoundingBoxes,
                boundingBoxInfos: singleModeBoundingBoxInfos,
                debugParams: viewModel.debugModeEnabled ? computeDebugParams(
                    mode: viewModel.debugMode,
                    boundsCenter: viewModel.boundsCenter,
                    boundsSize: viewModel.boundsSize
                ) : nil,
                sortManager: sortManager,
                cameraMode: viewModel.cameraMode
            )
            .ignoresSafeArea()
            .onGeometryChange(for: CGSize.self, of: \.size) { viewModel.viewSize = $0 }
        } else {
            ProgressView("Initializing...")
        }
    }

    /// Compute debug shader parameters based on mode and bounds
    private func computeDebugParams(mode: SplatDebugMode, boundsCenter: SIMD3<Float>, boundsSize: SIMD3<Float>, cloudCount: UInt32 = 1, cloudColors: [SIMD3<Float>] = []) -> DebugParams {
        let maxExtent = max(boundsSize.x, max(boundsSize.y, boundsSize.z))
        switch mode {
        case .distanceFromCenter:
            return .distance(DebugDistanceParams(center: boundsCenter, maxDistance: maxExtent / 2))
        case .splatSize:
            return .size(DebugSizeParams(minSize: 0, maxSize: maxExtent / 50))
        case .depth:
            return .depth(DebugDepthParams(minDepth: 0, maxDepth: maxExtent * 2))
        case .opacity:
            return .opacity
        case .normal:
            return .normal
        case .aspectRatio:
            return .aspectRatio(DebugAspectRatioParams(minRatio: 1.0, maxRatio: 10.0))
        case .cloudIndex:
            return .cloudIndex(DebugCloudIndexParams.withColors(cloudCount: cloudCount, colors: cloudColors))
        }
    }

    private var singleModeBoundingBoxInfos: [BoundingBoxInfo] {
        guard viewModel.showBoundingBoxes, viewModel.boundsSize != .zero else {
            return []
        }
        let bounds = BoundingBox(
            min: viewModel.boundsCenter - viewModel.boundsSize / 2,
            max: viewModel.boundsCenter + viewModel.boundsSize / 2
        )
        return [
            BoundingBoxInfo(
                id: UUID(),
                bounds: bounds,
                modelMatrix: viewModel.sceneTransform,
                color: .white
            )
        ]
    }

    @ViewBuilder
    private var multiRenderView: some View {
        if let doc = multiDocument, let sortManager = viewModel.sortManager {
            let enabledCloudIDs = Set(doc.scene.clouds.filter(\.enabled).map(\.id))

            // Build enabled clouds and collect their debug colors in the same order
            let preparedData: [(cloud: GPUSplatCloud<SparkSplat>, color: SIMD3<Float>)] = viewModel.loadedClouds
                .filter { enabledCloudIDs.contains($0.id) }
                .compactMap { loadedCloud in
                    guard let cloud = loadedCloud.cloud, let docCloud = doc.scene.clouds.first(where: { $0.id == loadedCloud.id }) else {
                        return nil
                    }
                    var transform = docCloud.transform
                    if let dragOffset = dragOffsets[loadedCloud.id] {
                        transform.translation += dragOffset
                    }
                    cloud.modelTransform = transform.matrix
                    cloud.opacity = docCloud.opacity
                    return (cloud: cloud, color: docCloud.debugColor)
                }

            let enabledClouds = preparedData.map(\.cloud)
            let enabledCloudColors = preparedData.map(\.color)

            let useSH = doc.scene.renderSettings.useSphericalHarmonics && viewModel.hasSphericalHarmonicsData

            SplatRenderView(
                mode: .multi,
                clouds: enabledClouds,
                sceneTransform: doc.scene.sceneTransform.matrix,
                useSphericalHarmonics: useSH,
                backgroundColor: doc.scene.renderSettings.backgroundColor,
                cameraMatrix: $viewModel.cameraMatrix,
                verticalAngleOfView: $viewModel.verticalAngleOfView,
                cullBoundingBox: viewModel.cullBoundingBox,
                showBoundingBoxes: viewModel.showBoundingBoxes,
                boundingBoxInfos: buildBoundingBoxInfos(),
                debugParams: viewModel.debugModeEnabled ? computeDebugParams(
                    mode: viewModel.debugMode,
                    boundsCenter: viewModel.boundsCenter,
                    boundsSize: viewModel.boundsSize,
                    cloudCount: UInt32(enabledClouds.count),
                    cloudColors: enabledCloudColors
                ) : nil,
                sortManager: sortManager,
                cameraMode: viewModel.cameraMode,
                onDragChange: handleAxisDrag,
                onDragEnd: commitDrag
            )
            .onGeometryChange(for: CGSize.self, of: \.size) { viewModel.viewSize = $0 }
        } else if multiDocument != nil {
            ProgressView("Initializing...")
        }
    }

    // MARK: - Inspector (Shared)

    @ViewBuilder
    private var inspectorContent: some View {
        switch mode {
        case .single:
            InspectorView(
                singleViewModel: viewModel,
                tab: $inspectorTab
            ) {
                showScreenshotSheet = true
            }

        case .multi:
            let selectedCloud: Binding<SplatScene.CloudReference?> = Binding(
                get: {
                    guard let selectedID = selectedCloudID, let index = multiDocument?.scene.clouds.firstIndex(where: { $0.id == selectedID }) else {
                        return nil
                    }
                    return multiDocument?.scene.clouds[index]
                },
                set: { newValue in
                    guard let newValue, let selectedID = selectedCloudID, let index = multiDocument?.scene.clouds.firstIndex(where: { $0.id == selectedID }) else {
                        return
                    }
                    multiDocument?.scene.clouds[index] = newValue
                }
            )

            InspectorView(
                multiViewModel: viewModel,
                document: $multiDocument,
                selectedCloud: selectedCloud,
                tab: $inspectorTab,
                onDeleteCloud: {
                    if let id = selectedCloudID {
                        multiDocument?.scene.clouds.removeAll { $0.id == id }
                        selectedCloudID = nil
                    }
                },
                onScreenshot: { showScreenshotSheet = true }
            )
        }
    }

    // MARK: - Toolbar (Shared)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Export PLY (single mode, image conversion only - specific workflow)
        if mode == .single, viewModel.isImageConversion, viewModel.convertedURL != nil {
            ToolbarItem(placement: .primaryAction) {
                Button("Export PLY", systemImage: "square.and.arrow.down") {
                    showExportDialog = true
                }
            }
        }

        // Inspector toggle (both modes)
        ToolbarItem(placement: .primaryAction) {
            Button(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
                withAnimation {
                    showInspector.toggle()
                }
            }
        }
    }

    // MARK: - Helper Content Views

    @ViewBuilder
    private func conversionContent(status: String) -> some View {
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
        guard let descriptor = viewModel.descriptor else {
            return false
        }
        if viewModel.isImageConversion {
            return false
        }
        return descriptor.splatCount >= 1_000_000 && !confirmedLoad
    }

    @ViewBuilder
    private var confirmationContent: some View {
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
    }

    // MARK: - Multi Mode Helpers

    private func buildBoundingBoxInfos() -> [BoundingBoxInfo] {
        guard let doc = multiDocument else {
            return []
        }
        return viewModel.loadedClouds
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
        guard let doc = multiDocument, let cloudIndex = doc.scene.clouds.firstIndex(where: { $0.id == cloudID }), let loadedCloud = viewModel.loadedClouds.first(where: { $0.id == cloudID }) else {
            return
        }
        let bounds = loadedCloud.bounds ?? BoundingBox(min: .zero, max: .one)
        let modelMatrix = doc.scene.sceneTransform.matrix * doc.scene.clouds[cloudIndex].transform.matrix
        let worldCenter = modelMatrix * SIMD4<Float>(bounds.center, 1)

        let axisVectors: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let axisWorld = (modelMatrix * SIMD4<Float>(axisVectors[axis], 0)).xyz
        let axisNorm = normalize(axisWorld)

        let mvp = projectionMatrix * viewMatrix
        let viewportSize = viewModel.viewSize

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

        guard let p0 = toScreen(worldCenter), let p1 = toScreen(worldCenter + SIMD4<Float>(axisNorm, 0)) else {
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

        if let cloud = loadedCloud.cloud {
            let docTransform = doc.scene.clouds[cloudIndex].transform
            var newTransform = docTransform
            newTransform.translation += dragOffsets[cloudID]!
            cloud.modelTransform = doc.scene.sceneTransform.matrix * newTransform.matrix
        }
    }

    private func commitDrag(cloudID: UUID) {
        guard let offset = dragOffsets[cloudID], offset != .zero, let cloudIndex = multiDocument?.scene.clouds.firstIndex(where: { $0.id == cloudID }) else {
            return
        }
        multiDocument?.scene.clouds[cloudIndex].transform.translation += offset
        dragOffsets[cloudID] = nil
    }

    /// Ensure there's always a cloud selected if clouds exist
    private func ensureSelection() {
        guard let doc = multiDocument else {
            return
        }
        // If current selection is invalid or nil, select the first cloud
        if selectedCloudID == nil || !doc.scene.clouds.contains(where: { $0.id == selectedCloudID }) {
            selectedCloudID = doc.scene.clouds.first?.id
        }
    }

    private func handleAddClouds(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            return
        }

        var cloudRefs: [(ref: SplatScene.CloudReference, didAccess: Bool)] = []

        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            do {
                let cloudRef = try SplatScene.CloudReference(url: url)
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

extension SplatDocumentContentView {
    /// Create view for single splat document
    init(document: SplatDocument, fileURL: URL?) {
        self.init(
            mode: .single,
            singleDocument: document,
            fileURL: fileURL,
            multiDocument: .constant(nil)
        )
    }

    /// Create view for multi-cloud scene document
    init(document: Binding<SplatSceneDocument>) {
        self.init(
            mode: .multi,
            singleDocument: nil,
            fileURL: nil,
            multiDocument: Binding(
                get: { document.wrappedValue },
                set: { document.wrappedValue = $0! }
            )
        )
    }
}

// MARK: - Cloud List Row

struct CloudListRow: View {
    @Binding var cloud: SplatScene.CloudReference
    var onDelete: () -> Void

    private var debugColorBinding: Binding<Color> {
        Binding(
            get: {
                // Convert linear to sRGB for display
                let linear = cloud.debugColor
                let srgb = SIMD3<Float>(
                    linearToSRGB(linear.x),
                    linearToSRGB(linear.y),
                    linearToSRGB(linear.z)
                )
                return Color(
                    red: Double(srgb.x),
                    green: Double(srgb.y),
                    blue: Double(srgb.z)
                )
            },
            set: { newColor in
                // Convert sRGB from picker to linear for storage
                if let components = newColor.cgColor?.components, components.count >= 3 {
                    cloud.debugColor = SIMD3<Float>(
                        srgbToLinear(Float(components[0])),
                        srgbToLinear(Float(components[1])),
                        srgbToLinear(Float(components[2]))
                    )
                }
            }
        )
    }

    private func srgbToLinear(_ value: Float) -> Float {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    private func linearToSRGB(_ value: Float) -> Float {
        if value <= 0.0031308 {
            return value * 12.92
        }
        return 1.055 * pow(value, 1.0 / 2.4) - 0.055
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $cloud.enabled)
                .labelsHidden()
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif

            Text(cloud.displayName ?? "Unknown")
                .lineLimit(1)
                .foregroundStyle(cloud.enabled ? .primary : .secondary)

            Spacer()

            ColorPicker("", selection: debugColorBinding, supportsOpacity: false)
                .labelsHidden()
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
