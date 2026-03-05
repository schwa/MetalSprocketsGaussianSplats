import Foundation
@testable import Splats
import Testing

@Suite
struct SplatReaderTests {
    @Test
    func testReadPLY() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "ply", subdirectory: "Fixtures")!
        let reader = try SplatReader(url: url)
        #expect(reader.splatCount == 100)
        var count = 0
        try reader.read { _, _ in count += 1 }
        #expect(count == 100)
    }

    @Test
    func testReadSplat() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "splat", subdirectory: "Fixtures")!
        let reader = try SplatReader(url: url)
        #expect(reader.splatCount == 100)
        var count = 0
        try reader.read { _, _ in count += 1 }
        #expect(count == 100)
    }

    @Test
    func testReadSOG() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "sog", subdirectory: "Fixtures")!
        let reader = try SplatReader(url: url)
        #expect(reader.splatCount == 100)
        var count = 0
        try reader.read { _, _ in count += 1 }
        #expect(count == 100)
    }

    @Test
    func testReadSPZ() throws {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures")!
        let reader = try SplatReader(url: url)
        #expect(reader.splatCount == 100)
        var count = 0
        try reader.read { _, _ in count += 1 }
        #expect(count == 100)
    }

    @Test
    func testUnsupportedExtension() throws {
        let url = URL(fileURLWithPath: "/tmp/test.xyz")
        #expect(throws: SplatsError.self) {
            try SplatReader(url: url)
        }
    }

    @Test
    func testDataInitThrows() throws {
        #expect(throws: SplatsError.self) {
            try SplatReader(data: Data())
        }
    }
}
