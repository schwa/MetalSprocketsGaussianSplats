#if os(visionOS)
import Foundation
import GeometryLite3D
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Observation
import simd

@Observable
@MainActor
final class ImmersiveState {
    var isImmersive = false
    var splatCloud: GPUSplatCloud<SparkSplat>?
    var modelMatrix = simd_float4x4(xRotation: .radians(.pi))

    static let shared = ImmersiveState()
    private init() {
        // This line intentionally left blank.
    }
}
#endif
