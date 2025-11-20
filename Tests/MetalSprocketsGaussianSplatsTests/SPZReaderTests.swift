import Foundation
@testable import MetalSprocketsGaussianSplats
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

        // Verify header
        #expect(reader.version == 2 || reader.version == 3)
        #expect(reader.pointCount > 0)
        #expect(reader.shDegree <= 3)

        print("Horned Lizard SPZ:")
        print("  Version: \(reader.version)")
        print("  Points: \(reader.pointCount)")
        print("  SH Degree: \(reader.shDegree)")
        print("  Antialiased: \(reader.isAntialiased)")

        // Read some splats
        var count = 0
        var firstSplat: SPZSplat?

        try reader.read { splat in
            if count == 0 {
                firstSplat = splat
            }
            count += 1
        }

        #expect(count == Int(reader.pointCount))
        #expect(firstSplat != nil)

        if let splat = firstSplat {
            print("  First splat position: \(splat.position)")
            print("  First splat alpha: \(splat.alpha)")
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

        #expect(reader.version == 2 || reader.version == 3)
        #expect(reader.pointCount > 0)

        print("Racoon Family SPZ:")
        print("  Version: \(reader.version)")
        print("  Points: \(reader.pointCount)")
        print("  SH Degree: \(reader.shDegree)")

        var count = 0
        try reader.read { _ in
            count += 1
        }

        #expect(count == Int(reader.pointCount))
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

        try reader.read { splat in
            guard sampleCount < maxSamples else {
                return
            }

            // Position should be reasonable (not NaN or infinite)
            #expect(!splat.position.x.isNaN && !splat.position.x.isInfinite)
            #expect(!splat.position.y.isNaN && !splat.position.y.isInfinite)
            #expect(!splat.position.z.isNaN && !splat.position.z.isInfinite)

            // Alpha should be valid
            #expect(!splat.alpha.isNaN && !splat.alpha.isInfinite)

            // Color components should be valid
            #expect(!splat.color.x.isNaN && !splat.color.x.isInfinite)
            #expect(!splat.color.y.isNaN && !splat.color.y.isInfinite)
            #expect(!splat.color.z.isNaN && !splat.color.z.isInfinite)

            // Scale components should be valid
            #expect(!splat.scale.x.isNaN && !splat.scale.x.isInfinite)
            #expect(!splat.scale.y.isNaN && !splat.scale.y.isInfinite)
            #expect(!splat.scale.z.isNaN && !splat.scale.z.isInfinite)

            // Rotation quaternion should be normalized (approximately)
            let rotVec = splat.rotation.vector
            let length = sqrt(rotVec.x * rotVec.x + rotVec.y * rotVec.y + rotVec.z * rotVec.z + rotVec.w * rotVec.w)
            #expect(abs(length - 1.0) < 0.01, "Quaternion should be normalized")

            sampleCount += 1
        }

        #expect(sampleCount > 0)
    }

    @Test("Spherical harmonics presence")
    func testSphericalHarmonics() throws {
        let url = Self.samplesURL.appendingPathComponent("hornedlizard.spz")

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Skipping test - sample file not found")
            return
        }

        let reader = try SPZReader(url: url)
        var firstSplat: SPZSplat?

        try reader.read { splat in
            if firstSplat == nil {
                firstSplat = splat
            }
        }

        guard let splat = firstSplat else {
            Issue.record("No splats read")
            return
        }

        if reader.shDegree > 0 {
            #expect(splat.sphericalHarmonics != nil, "SH should be present when shDegree > 0")

            if let sh = splat.sphericalHarmonics {
                let expectedCoeffs: Int
                switch reader.shDegree {
                case 1:
                    expectedCoeffs = 3
                case 2:
                    expectedCoeffs = 8
                case 3:
                    expectedCoeffs = 15
                default:
                    expectedCoeffs = 0
                }

                #expect(sh.count == expectedCoeffs)

                // Each coefficient should have 3 channels (RGB)
                for coeff in sh {
                    #expect(coeff.count == 3)
                }
            }
        } else {
            #expect(splat.sphericalHarmonics == nil, "SH should be nil when shDegree == 0")
        }
    }

    // MARK: - Error Tests

    @Test("Invalid gzip data throws error")
    func testInvalidGzipData() throws {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])

        #expect(throws: SPZError.self) {
            _ = try SPZReader(data: invalidData)
        }
    }

    @Test("Empty data throws error")
    func testEmptyData() throws {
        let emptyData = Data()

        #expect(throws: SPZError.self) {
            _ = try SPZReader(data: emptyData)
        }
    }

    @Test("Convert SPZSplat to Antimatter15Splat")
    func testSPZToAntimatter15Conversion() throws {
        let url = Self.samplesURL.appendingPathComponent("hornedlizard.spz")

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Skipping test - sample file not found")
            return
        }

        let reader = try SPZReader(url: url)
        var converted: [Antimatter15Splat] = []
        let maxConvert = 100

        try reader.read { splat in
            guard converted.count < maxConvert else {
                return
            }
            let antimatter15 = Antimatter15Splat(splat)
            converted.append(antimatter15)
        }

        #expect(converted.count == maxConvert)

        let first = converted[0]
        #expect(first.position.x.isFinite)
        #expect(first.scale.x.isFinite)
        #expect(first.color.x > 0 || first.color.x == 0)

        print("Successfully converted \(converted.count) SPZSplats to Antimatter15Splats")
    }
}
