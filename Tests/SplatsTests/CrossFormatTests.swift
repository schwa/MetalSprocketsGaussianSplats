import Foundation
import GeometryLite3D
import MetalSprocketsGaussianSplatShaders
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
        try plyReader.read { _, extendedSplat in plySplats.append(extendedSplat.genericSplat) }
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
            let plyQuat = ply.rotation
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
        try sogReader.read { _, extendedSplat in sogSplats.append(extendedSplat.genericSplat) }
        sogSplats.sort { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }

        #expect(sogSplats.count == csvSplats.count, "Count mismatch: SOG=\(sogSplats.count), CSV=\(csvSplats.count)")

        for i in 0..<sogSplats.count {
            let sog = sogSplats[i]
            let csv = csvSplats[i]

            #expect(sog.position.isApproximatelyEqual(to: csv.position, absoluteTolerance: 0.001))

            let expectedScale = SIMD3<Float>(exp(csv.scale.x), exp(csv.scale.y), exp(csv.scale.z))
            #expect(sog.scale.isApproximatelyEqual(to: expectedScale, absoluteTolerance: 0.0001))

            let sogQuat = sog.rotation
            let csvQuat = SIMD4<Float>(csv.rotation.imag.x, csv.rotation.imag.y, csv.rotation.imag.z, csv.rotation.real)
            #expect(sogQuat.isApproximatelyEqual(to: csvQuat, absoluteTolerance: 0.01))

            let SH_C0: Float = 0.28209479177387814
            let expectedColor = SIMD3<Float>(
                csv.color.x * SH_C0 + 0.5,
                csv.color.y * SH_C0 + 0.5,
                csv.color.z * SH_C0 + 0.5
            )
            let sogColor = SIMD3<Float>(sog.color.x, sog.color.y, sog.color.z)
            #expect(sogColor.isApproximatelyEqual(to: expectedColor, absoluteTolerance: 0.01))
        }
    }

    // MARK: - SPZ vs CSV

    @Test
    func testSPZMatchesCSV() throws {
        let csvSplats = try loadCSVGroundTruth().sorted { sortKeyCSV($0).lexicographicallyPrecedes(sortKeyCSV($1)) }

        let spzURL = Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures")!
        let spzReader = try SPZReader(url: spzURL)
        var spzSplats: [GenericSplat] = []
        try spzReader.read { _, extendedSplat in spzSplats.append(extendedSplat.genericSplat) }
        spzSplats.sort { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }

        #expect(spzSplats.count == csvSplats.count, "Count mismatch: SPZ=\(spzSplats.count), CSV=\(csvSplats.count)")

        for i in 0..<spzSplats.count {
            let spz = spzSplats[i]
            let csv = csvSplats[i]

            #expect(spz.position.isApproximatelyEqual(to: csv.position, absoluteTolerance: 0.0001))

            let expectedScale = SIMD3<Float>(exp(csv.scale.x), exp(csv.scale.y), exp(csv.scale.z))
            #expect(spz.scale.isApproximatelyEqual(to: expectedScale, absoluteTolerance: 0.001))

            let spzQuat = spz.rotation
            let csvQuat = SIMD4<Float>(csv.rotation.imag.x, csv.rotation.imag.y, csv.rotation.imag.z, csv.rotation.real)
            #expect(spzQuat.isApproximatelyEqual(to: csvQuat, absoluteTolerance: 0.01))

            let SH_C0: Float = 0.28209479177387814
            let expectedColor = SIMD3<Float>(
                csv.color.x * SH_C0 + 0.5,
                csv.color.y * SH_C0 + 0.5,
                csv.color.z * SH_C0 + 0.5
            )
            let spzColor = SIMD3<Float>(spz.color.x, spz.color.y, spz.color.z)
            #expect(spzColor.isApproximatelyEqual(to: expectedColor, absoluteTolerance: 0.01))
        }
    }

    // MARK: - Antimatter15 vs CSV

    @Test
    func testAntimatter15MatchesCSV() throws {
        let csvSplats = try loadCSVGroundTruth().sorted { sortKeyCSV($0).lexicographicallyPrecedes(sortKeyCSV($1)) }

        let splatURL = Bundle.module.url(forResource: "test-grid", withExtension: "splat", subdirectory: "Fixtures")!
        let splatReader = try Antimatter15Reader(url: splatURL)
        var splatSplats: [GenericSplat] = []
        try splatReader.read { _, extendedSplat in splatSplats.append(extendedSplat.genericSplat) }
        splatSplats.sort { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }

        #expect(splatSplats.count == csvSplats.count, "Count mismatch: SPLAT=\(splatSplats.count), CSV=\(csvSplats.count)")

        for i in 0..<splatSplats.count {
            let splat = splatSplats[i]
            let csv = csvSplats[i]

            #expect(splat.position.isApproximatelyEqual(to: csv.position, absoluteTolerance: 0.0001))

            let expectedScale = SIMD3<Float>(exp(csv.scale.x), exp(csv.scale.y), exp(csv.scale.z))
            #expect(splat.scale.isApproximatelyEqual(to: expectedScale, absoluteTolerance: 0.0001))

            let splatQuat = splat.rotation
            let csvQuat = SIMD4<Float>(csv.rotation.imag.x, csv.rotation.imag.y, csv.rotation.imag.z, csv.rotation.real)
            #expect(splatQuat.isApproximatelyEqual(to: csvQuat, absoluteTolerance: 0.01))

            let SH_C0: Float = 0.28209479177387814
            let expectedColor = SIMD3<Float>(
                csv.color.x * SH_C0 + 0.5,
                csv.color.y * SH_C0 + 0.5,
                csv.color.z * SH_C0 + 0.5
            )
            let splatColor = SIMD3<Float>(splat.color.x, splat.color.y, splat.color.z)
            #expect(splatColor.isApproximatelyEqual(to: expectedColor, absoluteTolerance: 0.01))
        }
    }
}
