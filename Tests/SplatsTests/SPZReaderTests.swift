import Foundation
import Testing
@testable import Splats

@Suite
struct SPZReaderTests {

    @Test
    func testSPZReader() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures")!
        let reader = try SPZReader(url: url)

        #expect(reader.splatCount == 100)

        var splats: [GenericSplat] = []
        try reader.read { _, splat in
            splats.append(splat)
        }

        #expect(splats.count == 100)

        // Check first splat has valid data
        // Note: SPZ stores scales in log space, so values can be negative
        let first = splats[0]
        #expect(first.position.x.isFinite)
        #expect(first.position.y.isFinite)
        #expect(first.position.z.isFinite)
        #expect(first.scale.x.isFinite)
    }
}
