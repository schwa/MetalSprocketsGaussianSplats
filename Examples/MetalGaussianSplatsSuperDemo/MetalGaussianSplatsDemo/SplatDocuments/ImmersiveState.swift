#if os(visionOS)
import Foundation
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Observation
import simd

@Observable
@MainActor
final class ImmersiveState {
    var isImmersive = false
    var splatCloud: GPUSplatCloud<SparkSplat>? {
        didSet {
            updateSortManager()
        }
    }
    var sortManager: AsyncSortManager<SparkSplat>?
    var sortedIndices: SplatIndices?
    private var sortListenerTask: Task<Void, Never>?
    var modelMatrix = simd_float4x4(xRotation: .radians(.pi))
    var scale: Float = 1.0
    var translation: SIMD3<Float> = .zero

    // Updated each frame from ImmersiveContent
    var headPosition: SIMD3<Float> = .zero
    var headForward: SIMD3<Float> = [0, 0, -1]

    static let shared = ImmersiveState()
    private init() {
        // This line intentionally left blank.
    }

    private func updateSortManager() {
        sortListenerTask?.cancel()
        sortListenerTask = nil
        sortedIndices = nil
        guard let splatCloud else {
            sortManager = nil
            return
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            sortManager = nil
            return
        }
        sortManager = try? AsyncSortManager(device: device, splatClouds: [splatCloud], capacity: splatCloud.count)
        if let sortManager {
            sortListenerTask = Task { @MainActor [weak self] in
                for await indices in sortManager.sortedIndicesStream {
                    self?.sortedIndices = indices
                }
            }
        }
    }

    func requestSort(cameraMatrix: simd_float4x4) {
        let worldModelMatrix = simd_float4x4(translation: translation)
            * simd_float4x4(scale: SIMD3<Float>(repeating: scale))
            * modelMatrix
        let parameters = SortParameters(camera: cameraMatrix, model: worldModelMatrix)
        sortManager?.requestSort(parameters)
    }

    func recenter(distance: Float = 2.0) {
        // Position the splat in front of the head
        translation = headPosition + headForward * distance
    }
}
#endif
