import Foundation
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
@testable import Splats
import Testing

@Suite("SPZReader Tests")
struct SPZReaderTests {
    // MARK: - Test Fixtures

    static let samplesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tmp")
        .appendingPathComponent("Reference")
        .appendingPathComponent("spz")
        .appendingPathComponent("samples")

    // MARK: - Basic Tests

    @Test("Read hornedlizard.spz sample file")
    func testReadHornedLizard() throws {
        let url = Self.samplesURL.appendingPathComponent("hornedlizard.spz")

        // Skip test if sample file doesn't exist
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Skipping test - sample file not found: \(url.path)")
            return
        }

        let reader = try SPZReader(url: url)

        // Read some splats
        var count = 0
        var firstSplat: GenericSplat?

        try reader.read { _, extendedSplat in
            if count == 0 {
                firstSplat = extendedSplat.genericSplat
            }
            count += 1
        }

        #expect(count > 0)
        #expect(firstSplat != nil)

        if let splat = firstSplat {
            print("  First splat position: \(splat.position)")
            print("  First splat color: \(splat.color)")
        }
    }

    @Test("Read racoonfamily.spz sample file")
    func testReadRacoonFamily() throws {
        let url = Self.samplesURL.appendingPathComponent("racoonfamily.spz")

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Skipping test - sample file not found: \(url.path)")
            return
        }

        let reader = try SPZReader(url: url)

        var count = 0
        try reader.read { _, _ in
            count += 1
        }

        #expect(count > 0)
    }

    @Test("Validate splat data ranges")
    func testSplatDataRanges() throws {
        let url = Self.samplesURL.appendingPathComponent("hornedlizard.spz")

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Skipping test - sample file not found")
            return
        }

        let reader = try SPZReader(url: url)
        var sampleCount = 0
        let maxSamples = 100

        try reader.read { _, extendedSplat in
            guard sampleCount < maxSamples else {
                return
            }

            let splat = extendedSplat.genericSplat

            // Position should be reasonable (not NaN or infinite)
            #expect(!splat.position.x.isNaN && !splat.position.x.isInfinite)
            #expect(!splat.position.y.isNaN && !splat.position.y.isInfinite)
            #expect(!splat.position.z.isNaN && !splat.position.z.isInfinite)

            // Color components should be valid
            #expect(!splat.color.x.isNaN && !splat.color.x.isInfinite)
            #expect(!splat.color.y.isNaN && !splat.color.y.isInfinite)
            #expect(!splat.color.z.isNaN && !splat.color.z.isInfinite)

            // Scale components should be valid
            #expect(!splat.scale.x.isNaN && !splat.scale.x.isInfinite)
            #expect(!splat.scale.y.isNaN && !splat.scale.y.isInfinite)
            #expect(!splat.scale.z.isNaN && !splat.scale.z.isInfinite)

            // Rotation quaternion should be normalized (approximately)
            let rot = splat.rotation
            let length = sqrt(rot.x * rot.x + rot.y * rot.y + rot.z * rot.z + rot.w * rot.w)
            #expect(abs(length - 1.0) < 0.01, "Quaternion should be normalized")

            sampleCount += 1
        }

        #expect(sampleCount > 0)
    }

    // MARK: - Error Tests

    @Test("Invalid gzip data throws error")
    func testInvalidGzipData() throws {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])

        #expect(throws: SplatsError.self) {
            _ = try SPZReader(data: invalidData)
        }
    }

    @Test("Empty data throws error")
    func testEmptyData() throws {
        let emptyData = Data()

        #expect(throws: SplatsError.self) {
            _ = try SPZReader(data: emptyData)
        }
    }

    @Test("Convert GenericSplat to Antimatter15Splat")
    func testSPZToAntimatter15Conversion() throws {
        let url = Self.samplesURL.appendingPathComponent("hornedlizard.spz")

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Skipping test - sample file not found")
            return
        }

        let reader = try SPZReader(url: url)
        var converted: [Antimatter15Splat] = []
        let maxConvert = 100

        try reader.read { _, extendedSplat in
            guard converted.count < maxConvert else {
                return
            }
            let antimatter15 = Antimatter15Splat(extendedSplat.genericSplat)
            converted.append(antimatter15)
        }

        #expect(converted.count == maxConvert)

        let first = converted[0]
        #expect(first.position.x.isFinite)
        #expect(first.scale.x.isFinite)
        #expect(first.color.x > 0 || first.color.x == 0)

        print("Successfully converted \(converted.count) GenericSplats to Antimatter15Splats")
    }
}
