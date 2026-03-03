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

// MARK: - Splat Render View

/// A unified content view for rendering splat clouds, used by both single-document and multi-cloud scene views
struct SplatRenderView: View {
    let mode: SplatContentMode
    let clouds: [GPUSplatCloud<SparkSplat>]
    let sceneTransform: simd_float4x4
    let useSphericalHarmonics: Bool
    let backgroundColor: [Float]

    @Binding var cameraMatrix: simd_float4x4
    @Binding var verticalAngleOfView: Double

    var cullBoundingBox: BoundingBox3D?
    var showBoundingBoxes: Bool = false
    var boundingBoxInfos: [BoundingBoxInfo] = []

    // Debug rendering (nil = normal rendering, non-nil = debug mode)
    var debugParams: DebugParams?

    // Sort manager (required)
    var sortManager: AsyncSortManager<SparkSplat>

    // Camera mode for selecting the appropriate controller
    var cameraMode: CameraMode = .object

    // Drag handling for multi-cloud mode
    var onDragChange: ((UUID, Int, CGSize, simd_float4x4, simd_float4x4) -> Void)?
    var onDragEnd: ((UUID) -> Void)?

    @State private var viewportSize: CGSize = .zero

    @Environment(SplatViewModel.self) private var viewModel

    var body: some View {
        ZStack {
            // Main render view
            cameraControlledRenderView

            // Bounding box overlay (multi-cloud mode only)
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
            if clouds.isEmpty {
                emptyStateOverlay
            }
        }
    }

    /// Render view with the appropriate camera controller applied based on camera mode
    @ViewBuilder
    private var cameraControlledRenderView: some View {
        let renderView = MultiCloudRenderView(
            clouds: clouds,
            cameraMatrix: cameraMatrix,
            sceneTransform: sceneTransform,
            verticalAngleOfView: verticalAngleOfView,
            useSphericalHarmonics: useSphericalHarmonics,
            backgroundColor: backgroundColor,
            cullBoundingBox: cullBoundingBox,
            sortManager: sortManager,
            debugParams: debugParams,
            onFrame: viewModel.recordFrame,
            sortingEnabled: viewModel.sortingEnabled
        )

        switch cameraMode {
        case .object:
            renderView.interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        case .room:
            renderView.roomCameraController(cameraMatrix: $cameraMatrix, cameraHeight: 0)
        case .spatialScene:
            renderView.modifier(SpatialSceneCameraController(transform: $cameraMatrix))
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        switch mode {
        case .single:
            ContentUnavailableView("No splat cloud loaded", systemImage: "cube.transparent")
                .background(.ultraThinMaterial)
        case .multi:
            ContentUnavailableView {
                Label("All Clouds Hidden", systemImage: "eye.slash")
            } description: {
                Text("Enable clouds in the sidebar to view")
            }
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var boundingBoxOverlay: some View {
        let projection = PerspectiveProjection(
            verticalAngleOfView: .degrees(Float(verticalAngleOfView)),
            depthMode: .standard(zClip: 0.01 ... 1_000)
        )
        let projectionMatrix = projection.projectionMatrix(for: viewportSize)
        let viewMatrix = cameraMatrix.inverse

        ZStack {
            if let onDragChange, let onDragEnd {
                BoundingBoxFaceInteraction(
                    boundingBoxes: boundingBoxInfos,
                    viewMatrix: viewMatrix,
                    projectionMatrix: projectionMatrix,
                    viewportSize: viewportSize,
                    onDragChange: { cloudID, axis, screenDelta in
                        onDragChange(cloudID, axis, screenDelta, viewMatrix, projectionMatrix)
                    },
                    onDragEnd: { cloudID in
                        onDragEnd(cloudID)
                    }
                )
            }

            BoundingBoxWireframe(
                boundingBoxes: boundingBoxInfos,
                viewMatrix: viewMatrix,
                projectionMatrix: projectionMatrix,
                viewportSize: viewportSize
            )
        }
    }
}

// MARK: - Inspector Tab

enum InspectorTab: String, CaseIterable {
    case cloud = "Cloud"
    case scene = "Scene"    // Multi-cloud mode only
    case camera = "Camera"
    case render = "Render"

    static func tabs(for mode: SplatContentMode) -> [Self] {
        switch mode {
        case .single:
            return [.cloud, .camera, .render]
        case .multi:
            return [.scene, .cloud, .camera, .render]
        }
    }
}

// MARK: - Inspector View

struct InspectorView: View {
    let mode: SplatContentMode
    @Bindable var viewModel: SplatViewModel
    @Binding var tab: InspectorTab

    // Multi-mode only: document and selection
    @Binding var document: SplatSceneDocument?
    @Binding var selectedCloud: SplatScene.CloudReference?
    var onDeleteCloud: (() -> Void)?
    var onScreenshot: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker - disable animations to prevent flicker during camera updates
            Picker("Tab", selection: $tab) {
                ForEach(InspectorTab.tabs(for: mode), id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            .transaction { $0.animation = nil }

            Divider()

            // Content based on tab
            Form {
                switch tab {
                case .cloud:
                    cloudContent

                case .scene:
                    if var doc = document {
                        SceneInspector(document: Binding(
                            get: { doc },
                            set: { doc = $0; document = $0 }
                        ))
                        .environment(viewModel)
                    }

                case .camera:
                    cameraContent

                case .render:
                    renderContent
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction { $0.animation = nil }
        }
    }

    // MARK: - Cloud Content

    @ViewBuilder
    private var cloudContent: some View {
        if mode == .multi, selectedCloud == nil {
            ContentUnavailableView("No Selection", systemImage: "cube.transparent", description: Text("Select a cloud to view its details"))
        } else {
            CloudInspector(
                descriptor: cloudDescriptor,
                rotationX: cloudRotationXBinding,
                rotationY: cloudRotationYBinding,
                rotationZ: cloudRotationZBinding,
                rotationSectionTitle: mode == .single ? "Model Orientation" : "Rotation",
                centerModel: $viewModel.centerModel,
                showCenterModel: mode == .single,
                displayName: cloudDisplayNameBinding,
                enabled: cloudEnabledBinding,
                opacity: cloudOpacityBinding,
                showCloudProperties: mode == .multi,
                transform: cloudTransformBinding,
                showTranslation: mode == .multi,
                onDelete: mode == .multi ? onDeleteCloud : nil
            )
        }
    }

    private var cloudDescriptor: SplatCloudDescriptor? {
        if mode == .single {
            return viewModel.descriptor
        }
        if let cloud = selectedCloud {
            return viewModel.loadedClouds.first { $0.id == cloud.id }?.descriptor
        }
        return nil
    }

    // Cloud bindings - single mode uses viewModel, multi mode uses selectedCloud
    private var cloudRotationXBinding: Binding<Float> {
        if mode == .single {
            return $viewModel.modelRotationX
        }
        return Binding(
            get: { selectedCloud?.transform.rotation.x ?? 0 },
            set: { selectedCloud?.transform.rotation.x = $0 }
        )
    }

    private var cloudRotationYBinding: Binding<Float> {
        if mode == .single {
            return $viewModel.modelRotationY
        }
        return Binding(
            get: { selectedCloud?.transform.rotation.y ?? 0 },
            set: { selectedCloud?.transform.rotation.y = $0 }
        )
    }

    private var cloudRotationZBinding: Binding<Float> {
        if mode == .single {
            return $viewModel.modelRotationZ
        }
        return Binding(
            get: { selectedCloud?.transform.rotation.z ?? 0 },
            set: { selectedCloud?.transform.rotation.z = $0 }
        )
    }

    private var cloudDisplayNameBinding: Binding<String?> {
        Binding(
            get: { selectedCloud?.displayName },
            set: { selectedCloud?.displayName = $0 }
        )
    }

    private var cloudEnabledBinding: Binding<Bool> {
        if mode == .single {
            return .constant(true)
        }
        return Binding(
            get: { selectedCloud?.enabled ?? true },
            set: { selectedCloud?.enabled = $0 }
        )
    }

    private var cloudOpacityBinding: Binding<Float> {
        if mode == .single {
            return .constant(1)
        }
        return Binding(
            get: { selectedCloud?.opacity ?? 1 },
            set: { selectedCloud?.opacity = $0 }
        )
    }

    private var cloudTransformBinding: Binding<Transform> {
        Binding(
            get: { selectedCloud?.transform ?? .identity },
            set: { selectedCloud?.transform = $0 }
        )
    }

    // MARK: - Camera Content

    /// Get the bounds center for the selected cloud (multi mode) or the overall bounds (single mode)
    private var selectedCloudBoundsCenter: SIMD3<Float> {
        guard mode == .multi,
            let cloud = selectedCloud,
            let loadedCloud = viewModel.loadedClouds.first(where: { $0.id == cloud.id }),
            let bounds = loadedCloud.bounds
        else {
            return viewModel.boundsCenter
        }
        // Transform the bounds center by the cloud's transform
        return (cloud.transform.matrix * SIMD4<Float>(bounds.center, 1)).xyz
    }

    /// Check if we have valid bounds for teleporting
    private var hasTeleportTarget: Bool {
        if mode == .multi {
            // In multi mode, need a selected cloud with bounds
            guard let cloud = selectedCloud,
                let loadedCloud = viewModel.loadedClouds.first(where: { $0.id == cloud.id }),
                loadedCloud.bounds != nil
            else {
                return false
            }
            return true
        }
        return viewModel.boundsSize != .zero
    }

    @ViewBuilder
    private var cameraContent: some View {
        CameraInspector(
            cameraMode: $viewModel.cameraMode,
            zoomToFit: $viewModel.zoomToFit,
            verticalAngleOfView: $viewModel.verticalAngleOfView,
            cameraMatrix: $viewModel.cameraMatrix,
            viewSize: viewModel.viewSize,
            zoomToFitDisabled: viewModel.boundsSize == .zero,
            boundsCenter: selectedCloudBoundsCenter,
            boundsSize: viewModel.boundsSize,
            teleportDisabled: !hasTeleportTarget
        )
    }

    // MARK: - Render Content

    @ViewBuilder
    private var renderContent: some View {
        RenderInspector(
            backgroundColor: $viewModel.backgroundColor,
            useSphericalHarmonics: $viewModel.useSphericalHarmonics,
            sphericalHarmonicsDisabled: !viewModel.hasSphericalHarmonicsData,
            sphericalHarmonicsWarning: sphericalHarmonicsWarning,
            showBoundingBoxes: $viewModel.showBoundingBoxes,
            debugModeEnabled: $viewModel.debugModeEnabled,
            debugMode: $viewModel.debugMode,
            lastSortEvent: viewModel.lastSortEvent,
            onScreenshot: onScreenshot
        ) {
            cullingSection
        }
    }

    private var sphericalHarmonicsWarning: String? {
        if mode == .single {
            return nil
        }
        if !viewModel.hasSphericalHarmonicsData {
            return "Not all clouds have SH data"
        }
        return nil
    }

    @ViewBuilder
    private var cullingSection: some View {
        NormalizedCullingSection(
            enabled: $viewModel.cullBoundingBoxEnabled,
            minBounds: $viewModel.cullMinNormalized,
            maxBounds: $viewModel.cullMaxNormalized,
            disabled: viewModel.boundsSize == .zero
        )
    }
}

// MARK: - Convenience Initializers

extension InspectorView {
    /// Create inspector for single splat mode
    init(
        singleViewModel: SplatViewModel,
        tab: Binding<InspectorTab>,
        onScreenshot: (() -> Void)? = nil
    ) {
        self.mode = .single
        self.viewModel = singleViewModel
        self._tab = tab
        self._document = .constant(nil)
        self._selectedCloud = .constant(nil)
        self.onDeleteCloud = nil
        self.onScreenshot = onScreenshot
    }

    /// Create inspector for multi-cloud mode
    init(
        multiViewModel: SplatViewModel,
        document: Binding<SplatSceneDocument?>,
        selectedCloud: Binding<SplatScene.CloudReference?>,
        tab: Binding<InspectorTab>,
        onDeleteCloud: (() -> Void)? = nil,
        onScreenshot: (() -> Void)? = nil
    ) {
        self.mode = .multi
        self.viewModel = multiViewModel
        self._tab = tab
        self._document = document
        self._selectedCloud = selectedCloud
        self.onDeleteCloud = onDeleteCloud
        self.onScreenshot = onScreenshot
    }
}
#endif
