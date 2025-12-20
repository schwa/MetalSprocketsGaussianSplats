import Foundation
import MetalSprocketsGaussianSplatShaders
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
        try reader.read { _, splat in
            splats.append(splat)
        }

        #expect(splats.count == 100)

        // Check first splat has valid data
        let first = splats[0]
        #expect(first.position.x.isFinite)
        #expect(first.position.y.isFinite)
        #expect(first.position.z.isFinite)
        #expect(first.scale.x > 0)
    }
}
