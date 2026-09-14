#if !arch(x86_64)
import GeometryLite3D
import Metal
import MetalSprockets
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

@Suite(.enabled(if: MetalTestSupport.supports64BitAtomics))
struct GPUSortPrecisionTests {
    @Test
    @MainActor
    func separatesNearbyDepthsAndSwitchesPrecision() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let splats = [Float(0), -0.0005, -0.0005].map { depth in
            SparkSplat(position: simd_half3(0, 0, Float16(depth)), scale: simd_half3(repeating: 0.1), rotation: simd_half4(0, 0, 0, 1), color: simd_uchar4(255, 255, 255, 255))
        }
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let runner = try Runner(device: device)
        for precision: SplatSortPrecision in [.float16, .float32, .float16] {
            let resources = try GPUSortResources(device: device, capacity: cloud.count, slotCount: 1, precision: precision)
            let slot = resources.advance()
            let pass = try GPUSplatSortComputePass(splatCloud: cloud, projectionMatrix: .identity, modelMatrix: simd_float4x4(translation: [0, 0, -2]), cameraMatrix: .identity, cullEnabled: false, resources: resources, slotIndex: slot)
            try runner.run(pass)
            let indices = resources.makeIndices(slot: slot, count: cloud.count, parameters: SortParameters(camera: .identity, model: .identity))
            #expect(indices.indices.map(\.splatIndex) == (precision == .float16 ? [0, 1, 2] : [1, 2, 0]))
            #expect(indices.indices.allSatisfy { $0.cloudIndex == 0 })
        }
    }
}
#endif
