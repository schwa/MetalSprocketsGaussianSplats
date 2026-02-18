#if os(iOS) || os(macOS)
import CoreGraphics
import Foundation
import GeometryLite3D
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

    // Per-cloud settings
    var enabled: Bool = true
    var opacity: Float = 1.0
    var transform: Transform = .identity

    /// Whether this cloud is fully loaded and ready to render
    var isLoaded: Bool { cloud != nil }
}

// MARK: - Unified Splat View Model

@Observable
@MainActor
final class UnifiedSplatViewModel {
    // MARK: - Loaded Clouds

    /// All loaded splat clouds
    var loadedClouds: [LoadedSplatCloud] = []

    /// Loading state
    var loadingState: SplatLoadingState = .idle

    // MARK: - Scene Transform

    /// Global scene transform applied to all clouds
    var sceneTransform: Transform = Transform(rotation: [.pi, 0, 0])

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
        didSet { updateCameraForZoomToFit() }
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

    /// Computed culling bounding box in world space
    var cullBoundingBox: BoundingBox3D? {
        guard cullBoundingBoxEnabled, combinedBoundsSize != .zero else {
            return nil
        }
        let actualMin = combinedBoundsCenter - combinedBoundsSize / 2
        let minBounds = actualMin + cullMinNormalized * combinedBoundsSize
        let maxBounds = actualMin + cullMaxNormalized * combinedBoundsSize
        return BoundingBox3D(minBounds: minBounds, maxBounds: maxBounds)
    }

    // MARK: - Computed Bounds

    /// Combined bounds of all enabled clouds (in world space after transforms)
    private(set) var combinedBoundsCenter: SIMD3<Float> = .zero
    private(set) var combinedBoundsSize: SIMD3<Float> = .zero

    // MARK: - Image Conversion State (for single-file mode)

    var sourceImage: PlatformImage?
    var isImageConversion: Bool = false
    var convertedURL: URL?
    private var sharp: Sharp?

    // MARK: - Resource Access (for multi-file mode)

    private nonisolated(unsafe) var resourceAccess = ScopedResourceAccess()
    private var loadedCloudIDs: Set<UUID> = []

    // MARK: - Computed Properties

    /// Whether all loaded clouds have spherical harmonics data
    var hasSphericalHarmonicsData: Bool {
        guard !loadedClouds.isEmpty else {
            return false
        }
        return loadedClouds.allSatisfy(\.descriptor.hasSphericalHarmonics)
    }

    /// Get enabled clouds for rendering
    var enabledClouds: [GPUSplatCloud<SparkSplat>] {
        loadedClouds.filter { $0.enabled && $0.cloud != nil }.compactMap(\.cloud)
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

    /// Descriptor for single-cloud mode
    var singleCloudDescriptor: SplatCloudDescriptor? {
        loadedClouds.first?.descriptor
    }

    // MARK: - Loading (Single File)

    /// Load a single splat file (for single-document mode)
    func loadSingleFile(url: URL?, contentType: UTType?) async {
        guard let url else {
            reset()
            return
        }

        // Check if this is an image that needs conversion
        if let contentType, contentType.conforms(to: .image) {
            isImageConversion = true
            cameraMode = .spatialScene
            verticalAngleOfView = 45
            sceneTransform = Transform(rotation: [0, 0, .pi])
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
                var bounds: BoundingBox?
                if let computedBounds = try? await descriptor.computeBounds() {
                    bounds = computedBounds
                }

                // Only auto-load if not a large file (< 1M splats)
                let gpuCloud: GPUSplatCloud<SparkSplat>?
                if descriptor.splatCount < 1_000_000 {
                    gpuCloud = try descriptor.loadGPUSplatCloud()
                    #if os(visionOS)
                    ImmersiveState.shared.splatCloud = gpuCloud
                    #endif
                } else {
                    // Store descriptor but don't load yet (large file)
                    gpuCloud = nil
                }

                let loadedCloud = LoadedSplatCloud(
                    id: UUID(),
                    displayName: url.deletingPathExtension().lastPathComponent,
                    cloud: gpuCloud,
                    descriptor: descriptor,
                    bounds: bounds
                )
                loadedClouds = [loadedCloud]
                updateCombinedBounds()
                loadingState = .ready
            } catch {
                loadingState = .error("Failed to load splat file: \(error.localizedDescription)")
            }
        }
    }

    /// Force load the splat cloud (for large files that weren't auto-loaded)
    func loadSplatCloudIfNeeded() {
        guard loadedClouds.count == 1,
              let first = loadedClouds.first,
              first.cloud == nil
        else {
            return
        }

        do {
            let gpuCloud: GPUSplatCloud<SparkSplat> = try first.descriptor.loadGPUSplatCloud()
            loadedClouds[0] = LoadedSplatCloud(
                id: first.id,
                displayName: first.displayName,
                cloud: gpuCloud,
                descriptor: first.descriptor,
                bounds: first.bounds,
                enabled: first.enabled,
                opacity: first.opacity,
                transform: first.transform
            )

            #if os(visionOS)
            ImmersiveState.shared.splatCloud = gpuCloud
            #endif
        } catch {
            loadingState = .error("Failed to load splat cloud: \(error.localizedDescription)")
        }
    }

    // MARK: - Loading (Multi-Cloud Scene)

    /// Load clouds from a scene document (for multi-cloud mode)
    func loadFromScene(_ scene: SplatScene) {
        let sceneCloudIDs = Set(scene.clouds.map(\.id))

        // Only reload if structural change (add/remove clouds)
        guard sceneCloudIDs != loadedCloudIDs else {
            // Just update transforms/settings from existing clouds
            updateCloudSettings(from: scene)
            return
        }

        loadedCloudIDs = sceneCloudIDs

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

                    // Find matching scene cloud for settings
                    let sceneCloud = scene.clouds.first { $0.id == resolvedCloud.id }

                    loaded.append(LoadedSplatCloud(
                        id: resolvedCloud.id,
                        displayName: resolvedCloud.displayName ?? resolvedCloud.url.lastPathComponent,
                        cloud: gpuCloud,
                        descriptor: descriptor,
                        bounds: nil,
                        enabled: sceneCloud?.enabled ?? true,
                        opacity: sceneCloud?.opacity ?? 1.0,
                        transform: sceneCloud?.transform ?? .identity
                    ))
                } catch {
                    // Skip clouds that fail to load
                }
            }

            loadedClouds = loaded

            // Apply scene settings
            sceneTransform = scene.sceneTransform
            if let camera = scene.camera {
                cameraMatrix = camera.matrix
                verticalAngleOfView = camera.verticalAngleOfView
            }
            useSphericalHarmonics = scene.renderSettings.useSphericalHarmonics
            let bg = scene.renderSettings.backgroundColor
            if bg.count == 4 {
                backgroundColor = Color(red: Double(bg[0]), green: Double(bg[1]), blue: Double(bg[2]), opacity: Double(bg[3]))
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

    /// Update cloud settings from scene without reloading
    private func updateCloudSettings(from scene: SplatScene) {
        for i in loadedClouds.indices {
            if let sceneCloud = scene.clouds.first(where: { $0.id == loadedClouds[i].id }) {
                loadedClouds[i].enabled = sceneCloud.enabled
                loadedClouds[i].opacity = sceneCloud.opacity
                loadedClouds[i].transform = sceneCloud.transform

                // Update GPU cloud transform
                loadedClouds[i].cloud?.modelTransform = sceneCloud.transform.matrix
                loadedClouds[i].cloud?.opacity = sceneCloud.opacity
            }
        }
        sceneTransform = scene.sceneTransform
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
            await loadSingleFile(url: outputURL, contentType: .ply)
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
            updateCombinedBounds()
        }
    }

    /// Update combined bounds from all enabled clouds
    func updateCombinedBounds() {
        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var hasBounds = false

        for cloud in loadedClouds where cloud.enabled {
            guard let bounds = cloud.bounds else {
                continue
            }

            let transform = sceneTransform.matrix * cloud.transform.matrix
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
            combinedBoundsCenter = (minBounds + maxBounds) / 2
            combinedBoundsSize = maxBounds - minBounds
        } else {
            combinedBoundsCenter = .zero
            combinedBoundsSize = .zero
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
        guard combinedBoundsSize != .zero else {
            return
        }

        let screenAspect = Float(viewSize.width / viewSize.height)
        let fovRadians = Float(verticalAngleOfView) * .pi / 180
        let halfFovTan = tan(fovRadians / 2)

        let modelWidth = combinedBoundsSize.x
        let modelHeight = combinedBoundsSize.y
        let modelDepth = combinedBoundsSize.z

        let distanceForHeight = (modelHeight / 2) / halfFovTan
        let distanceForWidth = (modelWidth / 2) / (halfFovTan * screenAspect)

        let distance = (max(distanceForHeight, distanceForWidth) + modelDepth / 2) / 0.9

        cameraMatrix = .init(translation: [combinedBoundsCenter.x, combinedBoundsCenter.y, combinedBoundsCenter.z + distance])
    }

    // MARK: - Reset

    func reset() {
        loadedClouds = []
        loadingState = .idle
        convertedURL = nil
        sourceImage = nil
        isImageConversion = false
        combinedBoundsCenter = .zero
        combinedBoundsSize = .zero
        resourceAccess.stopAccessing()
        loadedCloudIDs = []
    }

    nonisolated deinit {
        resourceAccess.stopAccessing()
    }
}
#endif
