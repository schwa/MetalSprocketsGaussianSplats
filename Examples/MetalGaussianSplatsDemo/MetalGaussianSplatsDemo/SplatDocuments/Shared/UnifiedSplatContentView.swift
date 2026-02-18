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

// MARK: - Shared Camera Mode

/// Camera mode shared by both single and multi-cloud views
enum CameraMode: String, CaseIterable {
    case object = "Object"
    case room = "Room"
    case spatialScene = "Spatial Scene"

    var initialPosition: SIMD3<Float> {
        switch self {
        case .object:
            [0, 0, 5]
        case .room:
            [0, 0, 0]
        case .spatialScene:
            [0, 0, 0.2]
        }
    }
}

// MARK: - Unified Content View Mode

enum SplatContentMode {
    /// Single splat file - no sidebar, no add cloud
    case single
    /// Multi-cloud scene - sidebar with cloud list, add cloud enabled
    case multi
}

// MARK: - Unified Splat Content View

/// A unified content view for rendering splat clouds, used by both single-document and multi-cloud scene views
struct UnifiedSplatContentView: View {
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

    // Camera mode for selecting the appropriate controller
    var cameraMode: CameraMode = .object

    // Drag handling for multi-cloud mode
    var onDragChange: ((UUID, Int, CGSize, simd_float4x4, simd_float4x4) -> Void)?
    var onDragEnd: ((UUID) -> Void)?

    @State private var viewportSize: CGSize = .zero

    var body: some View {
        ZStack {
            // Main render view
            cameraControlledRenderView

            // Bounding box overlay (multi-cloud mode only)
            if showBoundingBoxes, mode == .multi {
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
            cameraMatrix: $cameraMatrix,
            sceneTransform: sceneTransform,
            verticalAngleOfView: $verticalAngleOfView,
            useSphericalHarmonics: useSphericalHarmonics,
            backgroundColor: backgroundColor,
            cullBoundingBox: cullBoundingBox,
            debugParams: debugParams
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

// MARK: - Unified Inspector Tab

enum UnifiedInspectorTab: String, CaseIterable {
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

// MARK: - Unified Inspector View

struct UnifiedInspectorView: View {
    let mode: SplatContentMode
    @Binding var tab: UnifiedInspectorTab

    // Single-mode bindings
    var singleViewModel: SplatDocumentViewModel?

    // Multi-mode bindings
    var multiViewModel: SplatSceneViewModel?
    @Binding var document: SplatSceneDocument?
    @Binding var selectedCloud: SplatScene.CloudReference?
    var onDeleteCloud: (() -> Void)?

    // Shared render state
    @Binding var showBoundingBoxes: Bool

    // Shared culling state
    @Binding var cullBoundingBoxEnabled: Bool
    @Binding var cullMinBounds: SIMD3<Float>
    @Binding var cullMaxBounds: SIMD3<Float>

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Tab", selection: $tab) {
                ForEach(UnifiedInspectorTab.tabs(for: mode), id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            // Content based on tab
            Form {
                switch tab {
                case .cloud:
                    cloudContent

                case .scene:
                    if let multiViewModel, var doc = document {
                        SceneInspectorContent(document: Binding(
                            get: { doc },
                            set: { doc = $0; document = $0 }
                        ))
                        .environment(multiViewModel)
                    }

                case .camera:
                    cameraContent

                case .render:
                    renderContent
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Cloud Content

    @ViewBuilder
    private var cloudContent: some View {
        if mode == .multi, selectedCloud == nil {
            ContentUnavailableView("No Selection", systemImage: "cube.transparent", description: Text("Select a cloud to view its details"))
        } else {
            UnifiedCloudInfoContent(
                descriptor: cloudDescriptor,
                rotationX: cloudRotationXBinding,
                rotationY: cloudRotationYBinding,
                rotationZ: cloudRotationZBinding,
                rotationSectionTitle: mode == .single ? "Model Orientation" : "Rotation",
                centerModel: cloudCenterModelBinding,
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

    // MARK: - Unified Cloud Bindings

    private var cloudDescriptor: SplatCloudDescriptor? {
        if let singleViewModel {
            return singleViewModel.descriptor
        }
        if let cloud = selectedCloud {
            return multiViewModel?.loadedClouds.first { $0.id == cloud.id }?.descriptor
        }
        return nil
    }

    private var cloudRotationXBinding: Binding<Float> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.modelRotationX }, set: { singleViewModel.modelRotationX = $0 })
        }
        return Binding(
            get: { selectedCloud?.transform.rotation.x ?? 0 },
            set: { selectedCloud?.transform.rotation.x = $0 }
        )
    }

    private var cloudRotationYBinding: Binding<Float> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.modelRotationY }, set: { singleViewModel.modelRotationY = $0 })
        }
        return Binding(
            get: { selectedCloud?.transform.rotation.y ?? 0 },
            set: { selectedCloud?.transform.rotation.y = $0 }
        )
    }

    private var cloudRotationZBinding: Binding<Float> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.modelRotationZ }, set: { singleViewModel.modelRotationZ = $0 })
        }
        return Binding(
            get: { selectedCloud?.transform.rotation.z ?? 0 },
            set: { selectedCloud?.transform.rotation.z = $0 }
        )
    }

    private var cloudCenterModelBinding: Binding<Bool> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.centerModel }, set: { singleViewModel.centerModel = $0 })
        }
        return .constant(false)
    }

    private var cloudDisplayNameBinding: Binding<String?> {
        Binding(
            get: { selectedCloud?.displayName },
            set: { selectedCloud?.displayName = $0 }
        )
    }

    private var cloudEnabledBinding: Binding<Bool> {
        if singleViewModel != nil {
            return .constant(true)
        }
        return Binding(
            get: { selectedCloud?.enabled ?? true },
            set: { selectedCloud?.enabled = $0 }
        )
    }

    private var cloudOpacityBinding: Binding<Float> {
        if singleViewModel != nil {
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

    @ViewBuilder
    private var cameraContent: some View {
        UnifiedCameraContent(
            cameraMode: cameraModeBinding,
            zoomToFit: zoomToFitBinding,
            verticalAngleOfView: verticalAngleOfViewBinding,
            cameraMatrix: cameraMatrixBinding,
            viewSize: currentViewSize,
            zoomToFitDisabled: zoomToFitIsDisabled
        )
    }

    private var cameraMatrixBinding: Binding<simd_float4x4> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.cameraMatrix }, set: { singleViewModel.cameraMatrix = $0 })
        }
        if let multiViewModel {
            return Binding(get: { multiViewModel.cameraMatrix }, set: { multiViewModel.cameraMatrix = $0 })
        }
        return .constant(.identity)
    }

    // MARK: - Unified Camera Bindings

    private var cameraModeBinding: Binding<CameraMode> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.cameraMode }, set: { singleViewModel.cameraMode = $0 })
        }
        if let multiViewModel {
            return Binding(get: { multiViewModel.cameraMode }, set: { multiViewModel.cameraMode = $0 })
        }
        return .constant(.object)
    }

    private var zoomToFitBinding: Binding<Bool> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.zoomToFit }, set: { singleViewModel.zoomToFit = $0 })
        }
        if let multiViewModel {
            return Binding(get: { multiViewModel.zoomToFit }, set: { multiViewModel.zoomToFit = $0 })
        }
        return .constant(false)
    }

    private var verticalAngleOfViewBinding: Binding<Double> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.verticalAngleOfView }, set: { singleViewModel.verticalAngleOfView = $0 })
        }
        if let multiViewModel {
            return Binding(get: { multiViewModel.verticalAngleOfView }, set: { multiViewModel.verticalAngleOfView = $0 })
        }
        return .constant(90)
    }

    private var currentViewSize: CGSize {
        singleViewModel?.viewSize ?? multiViewModel?.viewSize ?? .zero
    }

    private var zoomToFitIsDisabled: Bool {
        if singleViewModel != nil {
            return false
        }
        if let multiViewModel {
            return multiViewModel.combinedBoundsSize == .zero
        }
        return false
    }

    // MARK: - Render Content

    @ViewBuilder
    private var renderContent: some View {
        UnifiedRenderContent(
            backgroundColor: backgroundColorBinding,
            useSphericalHarmonics: useSphericalHarmonicsBinding,
            sphericalHarmonicsDisabled: sphericalHarmonicsIsDisabled,
            sphericalHarmonicsWarning: sphericalHarmonicsWarning,
            showBoundingBoxes: $showBoundingBoxes,
            debugModeEnabled: debugModeEnabledBinding,
            debugMode: debugModeBinding
        ) {
            cullingSection
        }
    }

    // MARK: - Debug Mode Bindings

    private var debugModeEnabledBinding: Binding<Bool> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.debugModeEnabled }, set: { singleViewModel.debugModeEnabled = $0 })
        }
        if let multiViewModel {
            return Binding(get: { multiViewModel.debugModeEnabled }, set: { multiViewModel.debugModeEnabled = $0 })
        }
        return .constant(false)
    }

    private var debugModeBinding: Binding<SplatDebugMode> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.debugMode }, set: { singleViewModel.debugMode = $0 })
        }
        if let multiViewModel {
            return Binding(get: { multiViewModel.debugMode }, set: { multiViewModel.debugMode = $0 })
        }
        return .constant(.distanceFromCenter)
    }

    // MARK: - Unified Render Bindings

    private var backgroundColorBinding: Binding<Color> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.backgroundColor }, set: { singleViewModel.backgroundColor = $0 })
        }
        return Binding(
            get: {
                guard let c = document?.scene.renderSettings.backgroundColor, c.count == 4 else {
                    return .black
                }
                return Color(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), opacity: Double(c[3]))
            },
            set: { newColor in
                let resolved = newColor.resolve(in: EnvironmentValues())
                document?.scene.renderSettings.backgroundColor = [
                    Float(resolved.red), Float(resolved.green), Float(resolved.blue), Float(resolved.opacity)
                ]
            }
        )
    }

    private var useSphericalHarmonicsBinding: Binding<Bool> {
        if let singleViewModel {
            return Binding(get: { singleViewModel.useSphericalHarmonics }, set: { singleViewModel.useSphericalHarmonics = $0 })
        }
        return Binding(
            get: { document?.scene.renderSettings.useSphericalHarmonics ?? false },
            set: { document?.scene.renderSettings.useSphericalHarmonics = $0 }
        )
    }

    private var sphericalHarmonicsIsDisabled: Bool {
        if let singleViewModel {
            return !singleViewModel.hasSphericalHarmonicsData
        }
        return !(multiViewModel?.allCloudsHaveSphericalHarmonics ?? false)
    }

    private var sphericalHarmonicsWarning: String? {
        if singleViewModel != nil {
            return nil
        }
        if !(multiViewModel?.allCloudsHaveSphericalHarmonics ?? true) {
            return "Not all clouds have SH data"
        }
        return nil
    }

    @ViewBuilder
    private var cullingSection: some View {
        if let singleViewModel {
            NormalizedCullingSection(
                enabled: Binding(get: { singleViewModel.cullBoundingBoxEnabled }, set: { singleViewModel.cullBoundingBoxEnabled = $0 }),
                minBounds: Binding(get: { singleViewModel.cullMinNormalized }, set: { singleViewModel.cullMinNormalized = $0 }),
                maxBounds: Binding(get: { singleViewModel.cullMaxNormalized }, set: { singleViewModel.cullMaxNormalized = $0 }),
                disabled: singleViewModel.boundsSize == .zero
            )
        } else {
            AbsoluteCullingSection(
                enabled: $cullBoundingBoxEnabled,
                minBounds: $cullMinBounds,
                maxBounds: $cullMaxBounds
            )
        }
    }
}

// MARK: - Convenience Initializers

extension UnifiedInspectorView {
    /// Create inspector for single splat mode
    init(
        singleViewModel: SplatDocumentViewModel,
        tab: Binding<UnifiedInspectorTab>,
        showBoundingBoxes: Binding<Bool> = .constant(false),
        cullBoundingBoxEnabled: Binding<Bool> = .constant(false),
        cullMinBounds: Binding<SIMD3<Float>> = .constant(.zero),
        cullMaxBounds: Binding<SIMD3<Float>> = .constant(.one)
    ) {
        self.mode = .single
        self._tab = tab
        self.singleViewModel = singleViewModel
        self.multiViewModel = nil
        self._document = .constant(nil)
        self._selectedCloud = .constant(nil)
        self.onDeleteCloud = nil
        self._showBoundingBoxes = showBoundingBoxes
        self._cullBoundingBoxEnabled = cullBoundingBoxEnabled
        self._cullMinBounds = cullMinBounds
        self._cullMaxBounds = cullMaxBounds
    }

    /// Create inspector for multi-cloud mode
    init(
        multiViewModel: SplatSceneViewModel,
        document: Binding<SplatSceneDocument?>,
        selectedCloud: Binding<SplatScene.CloudReference?>,
        tab: Binding<UnifiedInspectorTab>,
        onDeleteCloud: (() -> Void)? = nil,
        showBoundingBoxes: Binding<Bool>,
        cullBoundingBoxEnabled: Binding<Bool>,
        cullMinBounds: Binding<SIMD3<Float>>,
        cullMaxBounds: Binding<SIMD3<Float>>
    ) {
        self.mode = .multi
        self._tab = tab
        self.singleViewModel = nil
        self.multiViewModel = multiViewModel
        self._document = document
        self._selectedCloud = selectedCloud
        self.onDeleteCloud = onDeleteCloud
        self._showBoundingBoxes = showBoundingBoxes
        self._cullBoundingBoxEnabled = cullBoundingBoxEnabled
        self._cullMinBounds = cullMinBounds
        self._cullMaxBounds = cullMaxBounds
    }
}
#endif
