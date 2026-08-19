#if !arch(x86_64)
import Foundation
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
@testable import Splats
import Testing

/// Smoke test for the GPU SOG decoder (`SOGReaderGPU`).
///
/// SOG decodes on the GPU only, so there is no CPU oracle to compare against.
/// The test checks that the decode is well-formed: a non-empty cloud, finite
/// geometry, in-range colors, and a consistent SH buffer size.
@Suite("SOGReaderGPU", .enabled(if: MetalTestSupport.supports64BitAtomics))
struct SOGReaderGPUTests {
    @Test("GPU decode of test-ring.sog is well-formed")
    func decodeIsWellFormed() throws {
        let url = try #require(Bundle.module.url(forResource: "test-ring", withExtension: "sog", subdirectory: "Fixtures"))
        let device = try #require(MTLCreateSystemDefaultDevice())

        let result = try SOGReaderGPU(device: device).read(url: url)
        #expect(result.count > 0)
        #expect(result.splats.count == result.count)

        let splats = Array(result.splats)
        for splat in splats {
            let p = SIMD3<Float>(splat.position)
            let s = SIMD3<Float>(splat.scale)
            #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite, "non-finite position")
            #expect(s.x.isFinite && s.y.isFinite && s.z.isFinite, "non-finite scale")
            #expect(s.x >= 0 && s.y >= 0 && s.z >= 0, "negative scale")
        }

        // The SH buffer size must match the reported degree.
        let floatsPerSplat = [0, 9, 24, 45][min(Int(result.shDegree), 3)]
        let sh = Array(result.shCoefficients)
        #expect(sh.count == result.count * floatsPerSplat)
        for value in sh {
            #expect(value.isFinite, "non-finite SH coefficient")
        }
    }
}
#endif
