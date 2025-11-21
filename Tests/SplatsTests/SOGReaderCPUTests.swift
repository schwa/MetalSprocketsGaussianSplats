import Foundation
import Testing
@testable import Splats

@Suite
struct SOGReaderCPUTests {

    @Test
    func testSOGReaderCPU() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "sog", subdirectory: "Fixtures")!
        let reader = try SOGReaderCPU(url: url)

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
        #expect(first.color.w >= 0 && first.color.w <= 1)
    }

    @Test
    func testSOGReaderCPUFromData() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "sog", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let reader = try SOGReaderCPU(data: data)

        #expect(reader.splatCount == 100)
    }
}
