#if os(iOS) || os(macOS)
import Foundation
import GeometryLite3D
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import SwiftUI

@Observable
final class SplatSceneViewModel {
    enum LoadingState: Equatable {
        case idle
        case loading
        case ready
        case error(String)
    }

    var loadingState: LoadingState = .idle
    var loadedClouds: [LoadedCloud] = []
    var viewSize: CGSize = .zero {
        didSet { updateCameraForZoomToFit() }
    }

    // Debug rendering mode
    var debugModeEnabled: Bool = false
    var debugMode: SplatDebugMode = .distanceFromCenter

    // Camera
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

    /// Combined bounds of all enabled clouds (computed when bounds change)
    var combinedBoundsCenter: SIMD3<Float> = .zero
    var combinedBoundsSize: SIMD3<Float> = .zero

    /// Incremented when individual cloud bounds are computed
    var boundsUpdateCount: Int = 0

    /// Update camera to fit all enabled clouds
    func updateCameraForZoomToFit() {
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

    /// Compute combined bounds from enabled clouds with their transforms
    func updateCombinedBounds(for scene: SplatScene) {
        var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var hasBounds = false

        for cloud in scene.clouds where cloud.enabled {
            guard let loadedCloud = loadedClouds.first(where: { $0.id == cloud.id }),
                let bounds = loadedCloud.bounds
            else {
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

    private var resourceAccess = ScopedResourceAccess()

    /// Track which cloud IDs we've loaded to avoid reloading on property-only changes
    private var loadedCloudIDs: Set<UUID> = []

    struct LoadedCloud: Identifiable {
        let id: UUID
        let displayName: String
        let cloud: GPUSplatCloud<SparkSplat>
        let descriptor: SplatCloudDescriptor
        var bounds: BoundingBox?
    }

    /// Whether all loaded clouds have spherical harmonics data
    var allCloudsHaveSphericalHarmonics: Bool {
        guard !loadedClouds.isEmpty else {
            return false
        }
        return loadedClouds.allSatisfy(\.descriptor.hasSphericalHarmonics)
    }

    /// Check if we need to reload (structural change) vs just update properties
    func needsReload(for scene: SplatScene) -> Bool {
        let sceneCloudIDs = Set(scene.clouds.map(\.id))
        return sceneCloudIDs != loadedCloudIDs
    }

    @MainActor
    func loadClouds(from scene: SplatScene) {
        // Only reload if structural change (add/remove clouds)
        guard needsReload(for: scene) else {
            return
        }

        // Set target IDs immediately to prevent re-entry during async loading
        let targetCloudIDs = Set(scene.clouds.map(\.id))
        loadedCloudIDs = targetCloudIDs

        if scene.clouds.isEmpty {
            loadingState = .idle
            loadedClouds = []
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
                        modelTransform: resolvedCloud.transform.matrix
                    )
                    loaded.append(LoadedCloud(
                        id: resolvedCloud.id,
                        displayName: resolvedCloud.displayName ?? resolvedCloud.url.lastPathComponent,
                        cloud: gpuCloud,
                        descriptor: descriptor
                    ))
                } catch {
                    // Skip clouds that fail to load
                }
            }

            loadedClouds = loaded

            if let camera = scene.camera {
                cameraMatrix = camera.matrix
                verticalAngleOfView = camera.verticalAngleOfView
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

    /// Compute bounds for all loaded clouds that don't have them yet
    @MainActor
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

    deinit {
        resourceAccess.stopAccessing()
    }
}
#endif
