import Foundation
import MetalSprocketsGaussianSplatShaders
@testable import Splats
import Testing

@Suite
struct SPZReaderTests {
    @Test
    func testSPZReader() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures")!
        let reader = try SPZReader(url: url)

        #expect(reader.splatCount == 100)

        var splats: [GenericSplat] = []
        try reader.read { _, extendedSplat in
            splats.append(extendedSplat.genericSplat)
        }

        #expect(splats.count == 100)

        // SPZ stores scales in log space, so values can be negative.
        let first = splats[0]
        #expect(first.position.x.isFinite)
        #expect(first.position.y.isFinite)
        #expect(first.position.z.isFinite)
        #expect(first.scale.x.isFinite)
    }

    @Test
    func testSPZReaderV4() throws {
        let url = Bundle.module.url(forResource: "test-grid.v4", withExtension: "spz", subdirectory: "Fixtures")!
        let reader = try SPZReader(url: url)

        #expect(reader.version == 4)
        #expect(reader.splatCount == 100)

        var splats: [GenericSplat] = []
        try reader.read { _, extendedSplat in
            splats.append(extendedSplat.genericSplat)
        }

        #expect(splats.count == 100)
        #expect(splats[0].position.x.isFinite)
        #expect(splats[0].scale.x.isFinite)
    }
}
