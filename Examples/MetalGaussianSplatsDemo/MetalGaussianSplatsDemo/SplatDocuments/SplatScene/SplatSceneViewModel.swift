#if os(iOS) || os(macOS)
import Foundation
import GeometryLite3D
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import SwiftUI

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
    var verticalAngleOfView: Double = 90

    private var resourceAccess = ScopedResourceAccess()

    // Binding helpers for use in views
    var verticalAngleOfViewBinding: Binding<Double> {
        Binding(
            get: { self.verticalAngleOfView },
            set: { self.verticalAngleOfView = $0 }
        )
    }
    
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

    /// Total splat count across all loaded clouds
    var totalSplatCount: Int {
        loadedClouds.reduce(into: 0) { $0 += $1.cloud.count }
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
                        modelTransform: resolvedCloud.transform.matrix
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
