import Foundation
@testable import Splats
import Testing

@Suite
struct PLYSplatReaderTests {
    @Test
    func testPLYSplatReader() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "ply", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let reader = try PLYSplatReader(data: data)

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
        #expect(first.color.w > 0) // Has alpha
    }
}
