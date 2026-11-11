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
        #expect(result.count > 0) // swiftlint:disable:this empty_count
        #expect(result.splats.count == result.count)

        let splats = Array(result.splats)
        for splat in splats {
            let p = SIMD3<Float>(splat.position)
            let s = SIMD3<Float>(splat.scale)
            #expect(p.x.isFinite && p.y.isFinite && p.z.isFinite, "non-finite position")
            #expect(s.x.isFinite && s.y.isFinite && s.z.isFinite, "non-finite scale")
            #expect(s.x >= 0 && s.y >= 0 && s.z >= 0, "negative scale")
        }

        // Indexed SH: the buffer holds a shared palette, not one row per splat.
        let floatsPerSplat = [0, 9, 24, 45][min(Int(result.shDegree), 3)]
        let sh = Array(result.shCoefficients)
        if result.shDegree > 0 {
            #expect(floatsPerSplat > 0 && sh.count.isMultiple(of: floatsPerSplat))
            let paletteRows = sh.count / floatsPerSplat
            #expect(paletteRows > 0)
            #expect(splats.allSatisfy { Int($0.shIndex) < paletteRows }, "shIndex out of palette range")
        } else {
            #expect(sh.isEmpty)
        }
        for value in sh {
            #expect(value.isFinite, "non-finite SH coefficient")
        }
    }

    // MARK: - Version 3

    // The same scene written by splat-transform as v2 and v3. Positions, scales
    // and colors are coded the same way, so they must match. Rotations differ
    // only by quantization (v2 smallest-three vs v3 24-bit exponential map).
    @Test("v3 decodes like the same scene in v2", arguments: [("test-ring.v3", "test-ring.v2"), ("sog-v3-sh4", "sog-v3-sh4.v2")])
    func version3MatchesVersion2(v3Name: String, v2Name: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let v3 = try SOGReaderGPU(device: device).read(url: try fixture(v3Name))
        let v2 = try SOGReaderGPU(device: device).read(url: try fixture(v2Name))
        #expect(v3.count == v2.count)
        let v3Splats = Array(v3.splats)
        let v2Splats = Array(v2.splats)
        var worstRotation: Float = 0
        for (a, b) in zip(v3Splats, v2Splats) {
            #expect(simd_distance(SIMD3<Float>(a.position), SIMD3<Float>(b.position)) < 1e-3)
            #expect(simd_distance(SIMD3<Float>(a.scale), SIMD3<Float>(b.scale)) < 1e-3)
            // Each file clusters its own codebooks, so allow a few steps.
            // swiftlint:disable:next line_length
            let colorDifference = SIMD3<Int>(Int(a.color.x), Int(a.color.y), Int(a.color.z)) &- SIMD3<Int>(Int(b.color.x), Int(b.color.y), Int(b.color.z))
            #expect(max(abs(colorDifference.x), abs(colorDifference.y), abs(colorDifference.z)) <= 4, "color difference \(colorDifference)")
            let qa = simd_normalize(SIMD4<Float>(a.rotation))
            let qb = simd_normalize(SIMD4<Float>(b.rotation))
            worstRotation = max(worstRotation, 2 * acos(min(1, abs(simd_dot(qa, qb)))) * 180 / .pi)
        }
        // v3 is within 1.2° of the true rotation and v2 within about 2°.
        #expect(worstRotation < 4, "worst rotation difference \(worstRotation)°")
    }

    // v3 stores sqrt(opacity) with byte 204 = 1. Values above 1 are clamped,
    // since the renderer has no opaque-core profile. v2 already clamps to 1.
    @Test("v3 opacity decodes as (a / 204)², clamped to 1")
    func version3Opacity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let v3 = Array(try SOGReaderGPU(device: device).read(url: try fixture("sog-v3-sh4")).splats)
        let v2 = Array(try SOGReaderGPU(device: device).read(url: try fixture("sog-v3-sh4.v2")).splats)
        var worst = 0
        var total = 0
        for (a, b) in zip(v3, v2) {
            let difference = Int(a.color.w) - Int(b.color.w)
            worst = max(worst, abs(difference))
            total += difference
        }
        // v3 has 204 opacity steps up to 1, v2 has 255, so they differ by rounding only.
        #expect(worst <= 3, "worst alpha difference \(worst)")
        // Truncating to a byte instead of rounding darkens v3 by about half a step.
        let bias = Double(total) / Double(v3.count)
        #expect(abs(bias) < 0.25, "mean alpha difference \(bias)")
        #expect(v3.contains { $0.color.w == 255 })
    }

    // Four bands are read, and the renderer gets the first three (15 coefficients).
    // v2 of the same scene was reduced to three bands by the writer.
    @Test("v3 with 4 SH bands decodes as degree 3")
    func version3FourBands() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let v3 = try SOGReaderGPU(device: device).read(url: try fixture("sog-v3-sh4"))
        let v2 = try SOGReaderGPU(device: device).read(url: try fixture("sog-v3-sh4.v2"))
        #expect(v3.shDegree == 3)
        let v3Splats = Array(v3.splats)
        let v2Splats = Array(v2.splats)
        let v3SH = Array(v3.shCoefficients)
        let v2SH = Array(v2.shCoefficients)
        #expect(v3SH.count.isMultiple(of: 45))
        // Palettes are clustered separately, so compare each splat's coefficients.
        var worst: Float = 0
        for (a, b) in zip(v3Splats, v2Splats) {
            let rowA = Int(a.shIndex) * 45
            let rowB = Int(b.shIndex) * 45
            for index in 0..<45 {
                worst = max(worst, abs(v3SH[rowA + index] - v2SH[rowB + index]))
            }
        }
        #expect(worst < 0.05, "worst SH difference \(worst)")
    }

    @Test("versions above 3 are rejected")
    func futureVersionIsRejected() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try fixture("test-ring.v3")
        let archive = try Data(contentsOf: source)
        // Rewrite meta.json with "version":9.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sog-future-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("future.sog")
        try archive.write(to: copy)
        let meta = directory.appendingPathComponent("meta.json")
        try run("/usr/bin/unzip", "-o", copy.path, "meta.json", "-d", directory.path)
        let text = try String(contentsOf: meta, encoding: .utf8).replacingOccurrences(of: "\"version\":3", with: "\"version\":9")
        #expect(text.contains("\"version\":9"))
        try text.write(to: meta, atomically: true, encoding: .utf8)
        try run("/usr/bin/zip", "-j", copy.path, meta.path)
        #expect(throws: SplatsError.self) {
            try SOGReaderGPU(device: device).read(url: copy)
        }
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "sog", subdirectory: "Fixtures"))
    }

    private func run(_ executable: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
#endif
