import Foundation
import GeometryLite3D
import simd
@testable import Splats
import TabularData
import Testing

@Suite
struct CrossFormatTests {
    // MARK: - CSV Ground Truth

    struct CSVSplat {
        var position: SIMD3<Float>
        var scale: SIMD3<Float>      // log scale
        var color: SIMD3<Float>      // f_dc values
        var opacity: Float
        var rotation: simd_quatf
    }

    func loadCSVGroundTruth() throws -> [CSVSplat] {
        let url = Bundle.module.url(forResource: "test-grid", withExtension: "csv", subdirectory: "Fixtures")!
        let dataFrame = try DataFrame(contentsOfCSVFile: url)

        // Helper to get Float from any numeric type
        func toFloat(_ value: Any?) -> Float {
            switch value {
            case let v as Double:
                return Float(v)
            case let v as Int:
                return Float(v)
            case let v as Float:
                return v
            default:
                fatalError("Unexpected type: \(type(of: value))")
            }
        }

        var splats: [CSVSplat] = []

        for row in dataFrame.rows {
            let splat = CSVSplat(
                position: SIMD3<Float>(
                    toFloat(row["x"]),
                    toFloat(row["y"]),
                    toFloat(row["z"])
                ),
                scale: SIMD3<Float>(
                    toFloat(row["scale_0"]),
                    toFloat(row["scale_1"]),
                    toFloat(row["scale_2"])
                ),
                color: SIMD3<Float>(
                    toFloat(row["f_dc_0"]),
                    toFloat(row["f_dc_1"]),
                    toFloat(row["f_dc_2"])
                ),
                opacity: toFloat(row["opacity"]),
                rotation: simd_quatf(
                    ix: toFloat(row["rot_1"]),
                    iy: toFloat(row["rot_2"]),
                    iz: toFloat(row["rot_3"]),
                    r: toFloat(row["rot_0"])
                )
            )
            splats.append(splat)
        }

        return splats
    }

    // Sort key for position-based comparison
    func sortKey(_ splat: GenericSplat) -> [Float] {
        [splat.position.x, splat.position.y, splat.position.z]
    }

    func sortKeyCSV(_ splat: CSVSplat) -> [Float] {
        [splat.position.x, splat.position.y, splat.position.z]
    }

    // MARK: - PLY vs CSV

    @Test
    func testPLYMatchesCSV() throws {
        let csvSplats = try loadCSVGroundTruth().sorted { sortKeyCSV($0).lexicographicallyPrecedes(sortKeyCSV($1)) }

        let plyURL = Bundle.module.url(forResource: "test-grid", withExtension: "ply", subdirectory: "Fixtures")!
        let plyReader = try PLYSplatReader(url: plyURL)
        var plySplats: [GenericSplat] = []
        try plyReader.read { _, splat in plySplats.append(splat) }
        plySplats.sort { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }

        #expect(plySplats.count == csvSplats.count, "Count mismatch: PLY=\(plySplats.count), CSV=\(csvSplats.count)")

        for i in 0..<plySplats.count {
            let ply = plySplats[i]
            let csv = csvSplats[i]

            // Position
            #expect(ply.position.isApproximatelyEqual(to: csv.position, absoluteTolerance: 0.0001), "PLY position mismatch at \(i)")

            // Scale (PLY stores exp(log_scale))
            let expectedScale = SIMD3<Float>(exp(csv.scale.x), exp(csv.scale.y), exp(csv.scale.z))
            #expect(ply.scale.isApproximatelyEqual(to: expectedScale, absoluteTolerance: 0.0001), "PLY scale mismatch at \(i)")

            // Rotation (quaternion) - compare as SIMD4 for component equality
            let plyQuat = SIMD4<Float>(ply.rotation.imag.x, ply.rotation.imag.y, ply.rotation.imag.z, ply.rotation.real)
            let csvQuat = SIMD4<Float>(csv.rotation.imag.x, csv.rotation.imag.y, csv.rotation.imag.z, csv.rotation.real)
            #expect(plyQuat.isApproximatelyEqual(to: csvQuat, absoluteTolerance: 0.0001), "PLY rotation mismatch at \(i): got \(plyQuat), expected \(csvQuat)")

            // Color (PLY converts from f_dc using SH_C0)
            let SH_C0: Float = 0.28209479177387814
            let expectedColor = SIMD3<Float>(
                csv.color.x * SH_C0 + 0.5,
                csv.color.y * SH_C0 + 0.5,
                csv.color.z * SH_C0 + 0.5
            )
            let plyColor = SIMD3<Float>(ply.color.x, ply.color.y, ply.color.z)
            #expect(plyColor.isApproximatelyEqual(to: expectedColor, absoluteTolerance: 0.001), "PLY color mismatch at \(i)")
        }
    }

    // MARK: - SOG vs CSV

    @Test(.disabled("SOG k-means quantization collapses 10 colors to 3 centroids - format needs larger datasets"))
    func testSOGMatchesCSV() throws {
        let csvSplats = try loadCSVGroundTruth().sorted { sortKeyCSV($0).lexicographicallyPrecedes(sortKeyCSV($1)) }

        let sogURL = Bundle.module.url(forResource: "test-grid", withExtension: "sog", subdirectory: "Fixtures")!
        let sogReader = try SOGReaderCPU(url: sogURL)
        var sogSplats: [GenericSplat] = []
        try sogReader.read { _, splat in sogSplats.append(splat) }
        sogSplats.sort { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }

        #expect(sogSplats.count == csvSplats.count, "Count mismatch: SOG=\(sogSplats.count), CSV=\(csvSplats.count)")

        for i in 0..<sogSplats.count {
            let sog = sogSplats[i]
            let csv = csvSplats[i]

            // Position (SOG uses quantization)
            #expect(sog.position.isApproximatelyEqual(to: csv.position, absoluteTolerance: 0.001),
                "SOG position mismatch at \(i)")

            // Scale (compare exp(log_scale))
            let expectedScale = SIMD3<Float>(exp(csv.scale.x), exp(csv.scale.y), exp(csv.scale.z))
            #expect(sog.scale.isApproximatelyEqual(to: expectedScale, absoluteTolerance: 0.0001),
                "SOG scale mismatch at \(i)")

            // Rotation (quaternion) - SOG uses 8-bit quantization
            let sogQuat = SIMD4<Float>(sog.rotation.imag.x, sog.rotation.imag.y, sog.rotation.imag.z, sog.rotation.real)
            let csvQuat = SIMD4<Float>(csv.rotation.imag.x, csv.rotation.imag.y, csv.rotation.imag.z, csv.rotation.real)
            #expect(sogQuat.isApproximatelyEqual(to: csvQuat, absoluteTolerance: 0.01),
                "SOG rotation mismatch at \(i): got \(sogQuat), expected \(csvQuat)")

            // Color (SOG uses codebook quantization)
            let SH_C0: Float = 0.28209479177387814
            let expectedColor = SIMD3<Float>(
                csv.color.x * SH_C0 + 0.5,
                csv.color.y * SH_C0 + 0.5,
                csv.color.z * SH_C0 + 0.5
            )
            let sogColor = SIMD3<Float>(sog.color.x, sog.color.y, sog.color.z)
            #expect(sogColor.isApproximatelyEqual(to: expectedColor, absoluteTolerance: 0.01),
                "SOG color mismatch at \(i)")
        }
    }

    // MARK: - SPZ vs CSV

    @Test
    func testSPZMatchesCSV() throws {
        let csvSplats = try loadCSVGroundTruth().sorted { sortKeyCSV($0).lexicographicallyPrecedes(sortKeyCSV($1)) }

        let spzURL = Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures")!
        let spzReader = try SPZReader(url: spzURL)
        var spzSplats: [GenericSplat] = []
        try spzReader.read { _, splat in spzSplats.append(splat) }
        spzSplats.sort { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }

        #expect(spzSplats.count == csvSplats.count, "Count mismatch: SPZ=\(spzSplats.count), CSV=\(csvSplats.count)")

        for i in 0..<spzSplats.count {
            let spz = spzSplats[i]
            let csv = csvSplats[i]

            // Position
            #expect(spz.position.isApproximatelyEqual(to: csv.position, absoluteTolerance: 0.0001),
                "SPZ position mismatch at \(i)")

            // SPZ stores log scale directly
            #expect(spz.scale.isApproximatelyEqual(to: csv.scale, absoluteTolerance: 0.018),
                "SPZ scale mismatch at \(i)")

            // Rotation (quaternion)
            let spzQuat = SIMD4<Float>(spz.rotation.imag.x, spz.rotation.imag.y, spz.rotation.imag.z, spz.rotation.real)
            let csvQuat = SIMD4<Float>(csv.rotation.imag.x, csv.rotation.imag.y, csv.rotation.imag.z, csv.rotation.real)
            #expect(spzQuat.isApproximatelyEqual(to: csvQuat, absoluteTolerance: 0.01),
                "SPZ rotation mismatch at \(i): got \(spzQuat), expected \(csvQuat)")

            // Color - SPZ stores raw f_dc values (8-bit quantization requires ~0.02 tolerance)
            let spzColor = SIMD3<Float>(spz.color.x, spz.color.y, spz.color.z)
            #expect(spzColor.isApproximatelyEqual(to: csv.color, absoluteTolerance: 0.02),
                "SPZ color mismatch at \(i)")
        }
    }

    // MARK: - Antimatter15 vs CSV

    @Test
    func testAntimatter15MatchesCSV() throws {
        let csvSplats = try loadCSVGroundTruth().sorted { sortKeyCSV($0).lexicographicallyPrecedes(sortKeyCSV($1)) }

        let splatURL = Bundle.module.url(forResource: "test-grid", withExtension: "splat", subdirectory: "Fixtures")!
        let splatReader = try Antimatter15Reader(url: splatURL)
        var splatSplats: [GenericSplat] = []
        try splatReader.read { _, splat in splatSplats.append(splat) }
        splatSplats.sort { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }

        #expect(splatSplats.count == csvSplats.count, "Count mismatch: SPLAT=\(splatSplats.count), CSV=\(csvSplats.count)")

        for i in 0..<splatSplats.count {
            let splat = splatSplats[i]
            let csv = csvSplats[i]

            // Position
            #expect(splat.position.isApproximatelyEqual(to: csv.position, absoluteTolerance: 0.0001),
                "SPLAT position mismatch at \(i)")

            // Scale (compare exp(log_scale))
            let expectedScale = SIMD3<Float>(exp(csv.scale.x), exp(csv.scale.y), exp(csv.scale.z))
            #expect(splat.scale.isApproximatelyEqual(to: expectedScale, absoluteTolerance: 0.0001),
                "SPLAT scale mismatch at \(i)")

            // Rotation (quaternion) - Antimatter15 uses 8-bit quantization
            let splatQuat = SIMD4<Float>(splat.rotation.imag.x, splat.rotation.imag.y, splat.rotation.imag.z, splat.rotation.real)
            let csvQuat = SIMD4<Float>(csv.rotation.imag.x, csv.rotation.imag.y, csv.rotation.imag.z, csv.rotation.real)
            #expect(splatQuat.isApproximatelyEqual(to: csvQuat, absoluteTolerance: 0.01),
                "SPLAT rotation mismatch at \(i): got \(splatQuat), expected \(csvQuat)")

            // Color (Antimatter15 stores 8-bit RGB)
            let SH_C0: Float = 0.28209479177387814
            let expectedColor = SIMD3<Float>(
                csv.color.x * SH_C0 + 0.5,
                csv.color.y * SH_C0 + 0.5,
                csv.color.z * SH_C0 + 0.5
            )
            let splatColor = SIMD3<Float>(splat.color.x, splat.color.y, splat.color.z)
            #expect(splatColor.isApproximatelyEqual(to: expectedColor, absoluteTolerance: 0.01),
                "SPLAT color mismatch at \(i)")
        }
    }
}
