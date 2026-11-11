import Foundation
import MetalSprocketsGaussianSplatShaders
import simd
@testable import Splats
import Testing

@Suite
struct Antimatter15ReaderTests {
    @Test
    func testAntimatter15Reader() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "splat", subdirectory: "Fixtures")!
        let reader = try Antimatter15Reader(url: url)

        #expect(reader.splatCount == 100)

        var splats: [GenericSplat] = []
        try reader.read { _, extendedSplat in
            splats.append(extendedSplat.genericSplat)
        }

        #expect(splats.count == 100)

        // Check first splat has valid data
        let first = splats[0]
        #expect(first.position.x.isFinite)
        #expect(first.position.y.isFinite)
        #expect(first.position.z.isFinite)
        #expect(first.scale.x > 0)
    }

    // Rotation bytes decode as (b - 128) / 128, so bytes of 0 give (-1, -1, -1, -1),
    // length 2. Unnormalized, the shader scales the splat by |q|² = 4.
    @Test
    func rotationIsNormalized() throws {
        var record = Data(count: 32)
        record.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: Float(0.1), toByteOffset: 12, as: Float.self)
            bytes.storeBytes(of: Float(0.1), toByteOffset: 16, as: Float.self)
            bytes.storeBytes(of: Float(0.1), toByteOffset: 20, as: Float.self)
            bytes[27] = 255
        }
        var rotation: SIMD4<Float>?
        try Antimatter15Reader(data: record).read { _, splat in
            rotation = splat.genericSplat.rotation
        }
        let decoded = try #require(rotation)
        #expect(abs(simd_length(decoded) - 1) < 1e-5, "length \(simd_length(decoded))")
        #expect(simd_distance(decoded, SIMD4(repeating: -0.5)) < 1e-5)
    }
}
