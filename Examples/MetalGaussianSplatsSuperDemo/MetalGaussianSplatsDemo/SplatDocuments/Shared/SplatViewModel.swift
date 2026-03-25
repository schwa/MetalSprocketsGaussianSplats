#if os(iOS) || os(macOS)
import CoreGraphics
import Foundation
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Observation
import Sharp
import simd
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Loading State

enum SplatLoadingState: Equatable {
    case idle
    case loading
    case converting(status: String)
    case ready
    case error(String)
}

// MARK: - Loaded Cloud

/// A loaded splat cloud with its GPU data and metadata
struct LoadedSplatCloud: Identifiable {
    let id: UUID
    var displayName: String
    /// The GPU cloud (nil if not yet loaded, e.g. for large files awaiting confirmation)
    var cloud: GPUSplatCloud<SparkSplat>?
    let descriptor: SplatCloudDescriptor
    var bounds: BoundingBox?

    /// Whether this cloud is fully loaded and ready to render
    var isLoaded: Bool { cloud != nil }
}

// MARK: - Splat View Model

@Observable
@MainActor
final class SplatViewModel {
    // MARK: - Mode

    enum Mode {
        case single
        case multi
    }

    let mode: Mode

    /// Sort manager for async sorting with statistics
    var sortManager: AsyncSortManager<SparkSplat>?

    /// Latest sort event (updated from sort manager)
    var lastSortEvent: SortEvent?

    /// Whether sorting is enabled (when disabled, splats render with last sort order)
    var sortingEnabled: Bool = true

    /// Trigger a manual sort using current camera position
    func triggerManualSort() {
        guard let sortManager else {
            return
        }
        let params = SortParameters(camera: cameraMatrix, model: sceneTransform, reversed: false)
        sortManager.requestSort(params)
    }

    // MARK: - FPS Tracking

    /// Current FPS (updated every second)
    var currentFPS: Double = 0

    /// Frame count for FPS calculation
    private var frameCount: Int = 0
    private var lastFPSUpdate: CFAbsoluteTime = 0

    /// Call this from RenderView closure to track frames
    nonisolated func recordFrame() {
        let now = CFAbsoluteTimeGetCurrent()
        Task { @MainActor in
            frameCount += 1
            if now - lastFPSUpdate >= 1.0 {
                currentFPS = Double(frameCount) / (now - lastFPSUpdate)
                frameCount = 0
                lastFPSUpdate = now
            }
        }
    }

    init(mode: Mode = .single) {
        self.mode = mode
    }

    /// Creates or recreates the sort manager for the current clouds
    func updateSortManager(for clouds: [GPUSplatCloud<SparkSplat>]) {
        guard !clouds.isEmpty else {
            sortManager = nil
            return
        }
        let device = MTLCreateSystemDefaultDevice()!
        let capacity = clouds.reduce(0) { $0 + $1.count }
        sortManager = try? AsyncSortManager(device: device, splatClouds: clouds, capacity: capacity)

        // Listen for sort events
        if let sortManager {
            Task { @MainActor [weak self] in
                for await event in sortManager.sortEventStream {
                    self?.lastSortEvent = event
                }
            }
        }
    }

    // MARK: - Loaded Clouds

    /// All loaded splat clouds
    var loadedClouds: [LoadedSplatCloud] = []

    /// Loading state
    var loadingState: SplatLoadingState = .idle

    // MARK: - Scene Transform (single mode: model rotation)

    /// For single mode: rotation around X axis (default π to flip Y-up to Y-down)
    var modelRotationX: Float = .pi {
        didSet {
            updateSceneTransform()
            updateCameraForZoomToFit()
        }
    }
    var modelRotationY: Float = 0 {
        didSet {
            updateSceneTransform()
            updateCameraForZoomToFit()
        }
    }
    var modelRotationZ: Float = 0 {
        didSet {
            updateSceneTransform()
            updateCameraForZoomToFit()
        }
    }
    var centerModel: Bool = false {
        didSet {
            updateSceneTransform()
            updateCameraForZoomToFit()
        }
    }

    /// Computed scene transform matrix
    private(set) var sceneTransform = simd_float4x4(xRotation: .radians(.pi))

    private func updateSceneTransform() {
        let rotX = simd_float4x4(xRotation: .radians(modelRotationX))
        let rotY = simd_float4x4(yRotation: .radians(modelRotationY))
        let rotZ = simd_float4x4(zRotation: .radians(modelRotationZ))
        let rotation = rotZ * rotY * rotX
        if centerModel, let firstBounds = loadedClouds.first?.bounds {
            let translation = simd_float4x4(translation: -firstBounds.center)
            sceneTransform = rotation * translation
        } else {
            sceneTransform = rotation
        }
    }

    // MARK: - Camera

    var cameraMode: CameraMode = .object {
        didSet {
            if !zoomToFit {
                cameraMatrix = .init(translation: cameraMode.initialPosition)
            }
        }
    }
    var cameraMatrix: simd_float4x4 = .init(translation: [0, 0, 5])
    var verticalAngleOfView: Double = 90 {
        didSet { updateCameraForZoomToFit() }
    }
    var zoomToFit: Bool = false {
        didSet {
            if zoomToFit {
                updateCameraForZoomToFit()
            } else {
                cameraMatrix = .init(translation: cameraMode.initialPosition)
            }
        }
    }
    var viewSize: CGSize = .zero {
        didSet {
            guard viewSize != oldValue else {
                return
            }
            updateCameraForZoomToFit()
        }
    }

    // MARK: - Render Settings

    var backgroundColor: Color = .black
    var useSphericalHarmonics: Bool = true
    var showBoundingBoxes: Bool = false

    // MARK: - Debug Rendering

    var debugModeEnabled: Bool = false
    var debugMode: SplatDebugMode = .distanceFromCenter

    // MARK: - Culling

    var cullBoundingBoxEnabled: Bool = false
    /// Normalized culling bounds (0...1 relative to combined bounds)
    var cullMinNormalized: SIMD3<Float> = SIMD3(0, 0, 0)
    var cullMaxNormalized: SIMD3<Float> = SIMD3(1, 1, 1)

    /// Computed culling bounding box in model space
    var cullBoundingBox: BoundingBox3D? {
        guard cullBoundingBoxEnabled, boundsSize != .zero else {
            return nil
        }
        let actualMin = boundsCenter - boundsSize / 2
        let minBounds = actualMin + cullMinNormalized * boundsSize
        let maxBounds = actualMin + cullMaxNormalized * boundsSize
        return BoundingBox3D(minBounds: minBounds, maxBounds: maxBounds)
    }

    // MARK: - Bounds

    /// Bounds center (single cloud's center, or combined center for multi)
    private(set) var boundsCenter: SIMD3<Float> = .zero
    /// Bounds size (single cloud's size, or combined size for multi)
    private(set) var boundsSize: SIMD3<Float> = .zero

    /// Incremented when bounds are computed (triggers UI updates)
    var boundsUpdateCount: Int = 0

    // MARK: - Image Conversion State (for single-file mode)

    var sourceImage: PlatformImage?
    var isImageConversion: Bool = false
    var convertedURL: URL?
    private var sharp: Sharp?

    // MARK: - Resource Access (for multi-file mode)

    private var resourceAccess = ScopedResourceAccess()
    private var loadedCloudIDs: Set<UUID> = []

    // MARK: - Computed Properties

    /// First cloud's descriptor (for single mode info display)
    var descriptor: SplatCloudDescriptor? {
        loadedClouds.first?.descriptor
    }

    /// First cloud's GPU cloud (for single mode rendering)
    var splatCloud: GPUSplatCloud<SparkSplat>? {
        loadedClouds.first?.cloud
    }

    /// Whether all loaded clouds have spherical harmonics data
    var hasSphericalHarmonicsData: Bool {
        guard !loadedClouds.isEmpty else {
            return false
        }
        return loadedClouds.allSatisfy(\.descriptor.hasSphericalHarmonics)
    }

    /// Get enabled clouds for rendering (multi mode checks scene, single mode always returns all)
    func enabledClouds(from scene: SplatScene?) -> [GPUSplatCloud<SparkSplat>] {
        if let scene {
            let enabledIDs = Set(scene.clouds.filter(\.enabled).map(\.id))
            return loadedClouds
                .filter { enabledIDs.contains($0.id) && $0.cloud != nil }
                .compactMap(\.cloud)
        }
        return loadedClouds.compactMap(\.cloud)
    }

    /// Background color as float array for renderer
    var backgroundColorArray: [Float] {
        let resolved = backgroundColor.resolve(in: EnvironmentValues())
        return [Float(resolved.red), Float(resolved.green), Float(resolved.blue), Float(resolved.opacity)]
    }

    /// Whether SH should actually be used (enabled and available)
    var effectiveUseSphericalHarmonics: Bool {
        useSphericalHarmonics && hasSphericalHarmonicsData
    }

    // MARK: - Loading (Single File)

    /// Load a single splat file (for single-document mode)
    func load(url: URL?, contentType: UTType?) async {
        guard let url else {
            reset()
            return
        }

        // Check if this is an image that needs conversion
        if let contentType, contentType.conforms(to: .image) {
            isImageConversion = true
            cameraMode = .spatialScene
            verticalAngleOfView = 45
            modelRotationZ = .pi
            #if os(macOS)
            sourceImage = NSImage(contentsOf: url)
            #else
            sourceImage = UIImage(contentsOfFile: url.path)
            #endif
            await convertImage(url: url)
        } else {
            isImageConversion = false
            sourceImage = nil
            loadingState = .loading

            do {
                let descriptor = try SplatCloudDescriptor(url: url)

                // Compute bounds
                if let computedBounds = try? await descriptor.computeBounds() {
                    boundsCenter = computedBounds.center
                    boundsSize = computedBounds.size
                }

                // Only auto-load if not a large file (< 1M splats)
                let gpuCloud: GPUSplatCloud<SparkSplat>?
                if descriptor.splatCount < 1_000_000 {
                    gpuCloud = try descriptor.loadGPUSplatCloud()
                    #if os(visionOS)
                    ImmersiveState.shared.splatCloud = gpuCloud
                    #endif
                } else {
                    gpuCloud = nil
                }

                let loadedCloud = LoadedSplatCloud(
                    id: UUID(),
                    displayName: url.deletingPathExtension().lastPathComponent,
                    cloud: gpuCloud,
                    descriptor: descriptor,
                    bounds: BoundingBox(min: boundsCenter - boundsSize / 2, max: boundsCenter + boundsSize / 2)
                )
                loadedClouds = [loadedCloud]
                if let gpuCloud {
                    updateSortManager(for: [gpuCloud])
                }
                updateSceneTransform()
                loadingState = .ready
            } catch {
                loadingState = .error("Failed to load splat file: \(error.localizedDescription)")
            }
        }
    }

    /// Force load the splat cloud (for large files that weren't auto-loaded)
    func loadSplatCloud() {
        guard loadedClouds.count == 1, var first = loadedClouds.first, first.cloud == nil else {
            return
        }

        do {
            let gpuCloud: GPUSplatCloud<SparkSplat> = try first.descriptor.loadGPUSplatCloud()
            first = LoadedSplatCloud(
                id: first.id,
                displayName: first.displayName,
                cloud: gpuCloud,
                descriptor: first.descriptor,
                bounds: first.bounds
            )
            loadedClouds = [first]
            updateSortManager(for: [gpuCloud])

            #if os(visionOS)
            ImmersiveState.shared.splatCloud = gpuCloud
            #endif
        } catch {
            loadingState = .error("Failed to load splat cloud: \(error.localizedDescription)")
        }
    }

    // MARK: - Loading (Multi-Cloud Scene)

    /// Check if we need to reload (structural change) vs just update properties
    func needsReload(for scene: SplatScene) -> Bool {
        let sceneCloudIDs = Set(scene.clouds.map(\.id))
        return sceneCloudIDs != loadedCloudIDs
    }

    /// Load clouds from a scene document (for multi-cloud mode)
    func loadClouds(from scene: SplatScene) {
        // Only reload if structural change (add/remove clouds)
        guard needsReload(for: scene) else {
            return
        }

        let targetCloudIDs = Set(scene.clouds.map(\.id))
        loadedCloudIDs = targetCloudIDs

        if scene.clouds.isEmpty {
            loadingState = .idle
            loadedClouds = []
            return
        }

        loadingState = .loading
        resourceAccess.stopAccessing()

        do {
            let resolved = try resourceAccess.startAccessing(scene: scene)
            var loaded: [LoadedSplatCloud] = []

            for resolvedCloud in resolved {
                do {
                    let descriptor = try SplatCloudDescriptor(url: resolvedCloud.url)
                    let gpuCloud: GPUSplatCloud<SparkSplat> = try descriptor.loadGPUSplatCloud(
                        modelTransform: resolvedCloud.transform.matrix
                    )

                    loaded.append(LoadedSplatCloud(
                        id: resolvedCloud.id,
                        displayName: resolvedCloud.displayName ?? resolvedCloud.url.lastPathComponent,
                        cloud: gpuCloud,
                        descriptor: descriptor,
                        bounds: nil
                    ))
                } catch {
                    // Skip clouds that fail to load
                }
            }

            loadedClouds = loaded

            // Update sort manager for the new clouds
            updateSortManager(for: loaded.compactMap(\.cloud))

            if let camera = scene.camera {
                cameraMatrix = camera.matrix
                verticalAngleOfView = camera.verticalAngleOfView
                if let mode = CameraMode(rawValue: camera.mode.capitalized) {
                    cameraMode = mode
                }
            }

            loadingState = loaded.isEmpty ? .idle : .ready

            // Compute bounds in background
            Task {
                await computeBoundsForLoadedClouds()
            }
        } catch {
            loadingState = .error("Failed to load clouds: \(error.localizedDescription)")
        }
    }

    // MARK: - Image Conversion

    private func convertImage(url: URL) async {
        loadingState = .converting(status: "Initializing Sharp model...")

        do {
            if sharp == nil {
                if SharpModelManager.isModelDownloaded {
                    loadingState = .converting(status: "Loading cached model...")
                    sharp = try Sharp(modelURL: SharpModelManager.modelURL)
                } else {
                    loadingState = .error("Sharp model not found. Please download the model first.")
                    return
                }
            }

            guard let sharp else {
                loadingState = .error("Failed to initialize Sharp")
                return
            }

            let outputDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SharpOutput")
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let outputName = url.deletingPathExtension().lastPathComponent + ".ply"
            let outputURL = outputDir.appendingPathComponent(outputName)

            loadingState = .converting(status: "Converting to 3D Gaussian Splats...")

            try await Task.detached {
                try sharp.convert(from: url, to: outputURL)
            }.value

            loadingState = .converting(status: "Loading converted splat cloud...")

            convertedURL = outputURL
            await load(url: outputURL, contentType: .ply)
        } catch {
            loadingState = .error("Conversion failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Bounds Computation

    /// Compute bounds for all loaded clouds that don't have them yet
    func computeBoundsForLoadedClouds() async {
        var didComputeAny = false
        for i in loadedClouds.indices where loadedClouds[i].bounds == nil {
            do {
                let bounds = try await loadedClouds[i].descriptor.computeBounds()
                loadedClouds[i].bounds = bounds
                didComputeAny = true
            } catch {
                // Skip bounds computation for clouds that fail
            }
        }
        if didComputeAny {
            boundsUpdateCount += 1
        }
    }

    /// Update combined bounds from all enabled clouds (for multi mode)
    func updateCombinedBounds(for scene: SplatScene) {
        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var hasBounds = false

        for cloud in scene.clouds where cloud.enabled {
            guard let loadedCloud = loadedClouds.first(where: { $0.id == cloud.id }), let bounds = loadedCloud.bounds else {
                continue
            }

            let transform = scene.sceneTransform.matrix * cloud.transform.matrix
            let corners: [SIMD3<Float>] = [
                SIMD3(bounds.min.x, bounds.min.y, bounds.min.z),
                SIMD3(bounds.max.x, bounds.min.y, bounds.min.z),
                SIMD3(bounds.min.x, bounds.max.y, bounds.min.z),
                SIMD3(bounds.max.x, bounds.max.y, bounds.min.z),
                SIMD3(bounds.min.x, bounds.min.y, bounds.max.z),
                SIMD3(bounds.max.x, bounds.min.y, bounds.max.z),
                SIMD3(bounds.min.x, bounds.max.y, bounds.max.z),
                SIMD3(bounds.max.x, bounds.max.y, bounds.max.z)
            ]

            for corner in corners {
                let transformed = (transform * SIMD4<Float>(corner, 1)).xyz
                minBounds = min(minBounds, transformed)
                maxBounds = max(maxBounds, transformed)
            }
            hasBounds = true
        }

        if hasBounds {
            boundsCenter = (minBounds + maxBounds) / 2
            boundsSize = maxBounds - minBounds
        } else {
            boundsCenter = .zero
            boundsSize = .zero
        }

        if zoomToFit {
            updateCameraForZoomToFit()
        }
    }

    // MARK: - Camera

    private func updateCameraForZoomToFit() {
        guard zoomToFit, cameraMode == .object else {
            return
        }
        guard viewSize.width > 0, viewSize.height > 0 else {
            return
        }
        guard boundsSize != .zero else {
            return
        }

        if mode == .single {
            updateCameraForZoomToFitSingle()
        } else {
            updateCameraForZoomToFitMulti()
        }
    }

    private func updateCameraForZoomToFitSingle() {
        // Get the maximum extent of the bounding box (after rotation)
        let rotX = simd_float4x4(xRotation: .radians(modelRotationX))
        let rotY = simd_float4x4(yRotation: .radians(modelRotationY))
        let rotZ = simd_float4x4(zRotation: .radians(modelRotationZ))
        let rotation = rotZ * rotY * rotX

        // Transform the 8 corners of the bounding box and find the extents
        let center = centerModel ? SIMD3<Float>.zero : boundsCenter
        let halfSize = boundsSize / 2
        let corners: [SIMD3<Float>] = [
            center + [-halfSize.x, -halfSize.y, -halfSize.z],
            center + [halfSize.x, -halfSize.y, -halfSize.z],
            center + [-halfSize.x, halfSize.y, -halfSize.z],
            center + [halfSize.x, halfSize.y, -halfSize.z],
            center + [-halfSize.x, -halfSize.y, halfSize.z],
            center + [halfSize.x, -halfSize.y, halfSize.z],
            center + [-halfSize.x, halfSize.y, halfSize.z],
            center + [halfSize.x, halfSize.y, halfSize.z]
        ]

        var maxX: Float = 0
        var maxY: Float = 0
        var maxZ: Float = 0
        for corner in corners {
            let transformed = (rotation * SIMD4<Float>(corner, 1)).xyz
            maxX = max(maxX, abs(transformed.x))
            maxY = max(maxY, abs(transformed.y))
            maxZ = max(maxZ, abs(transformed.z))
        }

        let modelWidth = maxX * 2
        let modelHeight = maxY * 2
        let modelDepth = maxZ * 2

        let screenAspect = Float(viewSize.width / viewSize.height)
        let fovRadians = Float(verticalAngleOfView) * .pi / 180
        let halfFovTan = tan(fovRadians / 2)

        let distanceForHeight = (modelHeight / 2) / halfFovTan
        let distanceForWidth = (modelWidth / 2) / (halfFovTan * screenAspect)
        let distance = (max(distanceForHeight, distanceForWidth) + modelDepth / 2) / 0.9

        let modelCenter = centerModel ? SIMD3<Float>.zero : (rotation * SIMD4<Float>(boundsCenter, 1)).xyz
        cameraMatrix = .init(translation: [modelCenter.x, modelCenter.y, modelCenter.z + distance])
    }

    private func updateCameraForZoomToFitMulti() {
        let screenAspect = Float(viewSize.width / viewSize.height)
        let fovRadians = Float(verticalAngleOfView) * .pi / 180
        let halfFovTan = tan(fovRadians / 2)

        let modelWidth = boundsSize.x
        let modelHeight = boundsSize.y
        let modelDepth = boundsSize.z

        let distanceForHeight = (modelHeight / 2) / halfFovTan
        let distanceForWidth = (modelWidth / 2) / (halfFovTan * screenAspect)
        let distance = (max(distanceForHeight, distanceForWidth) + modelDepth / 2) / 0.9

        cameraMatrix = .init(translation: [boundsCenter.x, boundsCenter.y, boundsCenter.z + distance])
    }

    // MARK: - Reset

    func reset() {
        loadedClouds = []
        loadingState = .idle
        convertedURL = nil
        sourceImage = nil
        isImageConversion = false
        boundsCenter = .zero
        boundsSize = .zero
        resourceAccess.stopAccessing()
        loadedCloudIDs = []
    }

    deinit {
        MainActor.assumeIsolated {
            resourceAccess.stopAccessing()
        }
    }
}
#endif
