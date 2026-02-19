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
        guard let splatCloud else {
            sortManager = nil
            return
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            sortManager = nil
            return
        }
        sortManager = try? AsyncSortManager(device: device, splatClouds: [splatCloud], capacity: splatCloud.count)
    }

    func recenter(distance: Float = 2.0) {
        // Position the splat in front of the head
        translation = headPosition + headForward * distance
    }
}
#endif
