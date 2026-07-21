import CoreGraphics
import Foundation
import ImageIO
import simd
import ZIPFoundation

// MARK: - SOGReaderCPU

/// Reader for SOG (Splat Optimized GPU) files
/// Uses CPU-based conversion
public struct SOGReaderCPU: SplatReaderProtocol {
    private let splats: [GenericSplat]
    private let sphericalHarmonics: [[[Float]]]? // Per-splat SH coefficients, or nil if no SH data. Each splat has [[r,g,b], [r,g,b], ...]

    /// The degree of spherical harmonics (0 = none, 1-3 = higher-order SH)
    public let shDegree: UInt8

    public var splatCount: Int {
        splats.count
    }

    /// Load SOG data
    public init(data: Data) throws {
        // ZIP extraction requires a URL, so stage the data in a temp file.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sog")
        try data.write(to: tempURL)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let result = try Self.loadSplats(from: tempURL)
        self.splats = result.splats
        self.sphericalHarmonics = result.sphericalHarmonics
        self.shDegree = UInt8(result.shDegree)
    }

    /// Load SOG file from URL
    public init(url: URL) throws {
        let result = try Self.loadSplats(from: url)
        self.splats = result.splats
        self.sphericalHarmonics = result.sphericalHarmonics
        self.shDegree = UInt8(result.shDegree)
    }

    public func read(_ handler: (Int, ExtendedSplat) throws -> Void) throws {
        for (index, splat) in splats.enumerated() {
            let sh = sphericalHarmonics?[index]
            try handler(index, ExtendedSplat(genericSplat: splat, sphericalHarmonics: sh))
        }
    }

    // MARK: - Private

    private struct LoadResult {
        let splats: [GenericSplat]
        let sphericalHarmonics: [[[Float]]]? // [splat][coefficient][rgb]
        let shDegree: Int
    }

    private static func loadSplats(from url: URL) throws -> LoadResult {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw SplatsError.failedToExtractZIP
        }

        let metadataData = try extractData(from: archive, filename: "meta.json")
        let metadata = try JSONDecoder().decode(SOGReaderCPUMetadata.self, from: metadataData)

        let meansLowData = try loadImageData(from: archive, filename: metadata.means.files[0])
        let meansHighData = try loadImageData(from: archive, filename: metadata.means.files[1])
        let scalesData = try loadImageData(from: archive, filename: metadata.scales.files[0])
        let quatsData = try loadImageData(from: archive, filename: metadata.quats.files[0])
        let sh0Data = try loadImageData(from: archive, filename: metadata.sh0.files[0])

        // Higher-order SH data is optional
        var shCentroids: [UInt8]?
        var shLabels: [UInt8]?
        var shCentroidsWidth: Int = 0
        if let shN = metadata.shN, shN.files.count >= 2 {
            let centroidsResult = try loadImageDataWithSize(from: archive, filename: shN.files[0])
            shCentroids = centroidsResult.data
            shCentroidsWidth = centroidsResult.width
            shLabels = try loadImageData(from: archive, filename: shN.files[1])
        }

        let mins = SIMD3<Float>(metadata.means.mins[0], metadata.means.mins[1], metadata.means.mins[2])
        let maxs = SIMD3<Float>(metadata.means.maxs[0], metadata.means.maxs[1], metadata.means.maxs[2])

        var splats = [GenericSplat]()
        splats.reserveCapacity(metadata.count)

        var sphericalHarmonics: [[[Float]]]? // [splat][coefficient][rgb]
        var shDegree = 0
        if let shN = metadata.shN, shCentroids != nil, shLabels != nil {
            shDegree = shN.bands // bands 1-3 correspond to degree 1-3
            sphericalHarmonics = []
            sphericalHarmonics?.reserveCapacity(metadata.count)
        }

        let scalesCodebook = metadata.scales.codebook
        let sh0Codebook = metadata.sh0.codebook

        // Cumulative coefficients above DC for bands 1-3: 3, 3+5, 3+5+7.
        let coeffsPerBand = [3, 8, 15]

        for i in 0..<metadata.count {
            let offset = i * 4

            // Position: 16-bit normalized log-space coords split across low/high textures.
            let rawX = (UInt16(meansHighData[offset]) << 8) | UInt16(meansLowData[offset])
            let rawY = (UInt16(meansHighData[offset + 1]) << 8) | UInt16(meansLowData[offset + 1])
            let rawZ = (UInt16(meansHighData[offset + 2]) << 8) | UInt16(meansLowData[offset + 2])

            let tx = Float(rawX) / 65_535.0
            let ty = Float(rawY) / 65_535.0
            let tz = Float(rawZ) / 65_535.0

            let logX = mins.x + tx * (maxs.x - mins.x)
            let logY = mins.y + ty * (maxs.y - mins.y)
            let logZ = mins.z + tz * (maxs.z - mins.z)

            func invLog(_ v: Float) -> Float {
                let a = abs(v)
                let e = exp(a) - 1.0
                return v < 0 ? -e : e
            }

            let position = SIMD3<Float>(invLog(logX), invLog(logY), invLog(logZ))

            // Scale: each channel is a separate codebook index.
            let scaleXIndex = Int(scalesData[offset])
            let scaleYIndex = Int(scalesData[offset + 1])
            let scaleZIndex = Int(scalesData[offset + 2])
            let scale = SIMD3<Float>(
                exp(scalesCodebook[scaleXIndex]),
                exp(scalesCodebook[scaleYIndex]),
                exp(scalesCodebook[scaleZIndex])
            )

            // Rotation: smallest-3 encoding. RGB stores 3 quaternion components,
            // alpha (252-255) indicates which was dropped.
            let SQRT2: Float = 1.4142135623730951
            let r0 = (Float(quatsData[offset]) / 255.0 - 0.5) * SQRT2
            let r1 = (Float(quatsData[offset + 1]) / 255.0 - 0.5) * SQRT2
            let r2 = (Float(quatsData[offset + 2]) / 255.0 - 0.5) * SQRT2
            let rr = sqrt(max(0.0, 1.0 - r0 * r0 - r1 * r1 - r2 * r2))
            let rOrder = Int(quatsData[offset + 3]) - 252

            // Reconstruction order matches the PlayCanvas JS reference.
            let qx = rOrder == 0 ? r0 : rOrder == 1 ? rr : r1
            let qy = rOrder <= 1 ? r1 : rOrder == 2 ? rr : r2
            let qz = rOrder <= 2 ? r2 : rr
            let qw = rOrder == 0 ? rr : r0
            let rotation = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw).normalized

            // Color: each RGB channel byte indexes the 256-value SH0 codebook.
            let SH_C0: Float = 0.28209479177387814
            let rIndex = Int(sh0Data[offset])
            let gIndex = Int(sh0Data[offset + 1])
            let bIndex = Int(sh0Data[offset + 2])
            let r = max(0, min(1, sh0Codebook[rIndex] * SH_C0 + 0.5))
            let g = max(0, min(1, sh0Codebook[gIndex] * SH_C0 + 0.5))
            let b = max(0, min(1, sh0Codebook[bIndex] * SH_C0 + 0.5))

            let alpha = Float(sh0Data[offset + 3]) / 255.0

            let splat = GenericSplat(
                position: position,
                scale: scale,
                color: SIMD4<Float>(r, g, b, alpha),
                rotation: rotation
            )
            splats.append(splat)

            if let shN = metadata.shN, let centroids = shCentroids, let labels = shLabels {
                let numCoeffs = coeffsPerBand[shN.bands - 1]

                // 16-bit palette index packed into label RG bytes.
                let paletteIndex = Int(labels[offset]) + (Int(labels[offset + 1]) << 8)

                // Centroids palette: 64 entries per row, each entry numCoeffs RGB pixels wide.
                let entriesPerRow = 64
                let paletteU = (paletteIndex % entriesPerRow) * numCoeffs
                let paletteV = paletteIndex / entriesPerRow

                var shCoeffs = [[Float]]()
                shCoeffs.reserveCapacity(numCoeffs)

                for c in 0..<numCoeffs {
                    let pixelX = paletteU + c
                    let pixelY = paletteV
                    let pixelOffset = (pixelY * shCentroidsWidth + pixelX) * 4 // RGBA

                    // RGB values index the shN codebook.
                    let rIdx = Int(centroids[pixelOffset])
                    let gIdx = Int(centroids[pixelOffset + 1])
                    let bIdx = Int(centroids[pixelOffset + 2])

                    let shR = shN.codebook[rIdx]
                    let shG = shN.codebook[gIdx]
                    let shB = shN.codebook[bIdx]

                    shCoeffs.append([shR, shG, shB])
                }

                sphericalHarmonics?.append(shCoeffs)
            }
        }

        return LoadResult(splats: splats, sphericalHarmonics: sphericalHarmonics, shDegree: shDegree)
    }

    private static func extractData(from archive: Archive, filename: String) throws -> Data {
        guard let entry = archive[filename] else {
            throw SplatsError.missingTexture(filename)
        }

        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func loadImageData(from archive: Archive, filename: String) throws -> [UInt8] {
        let result = try loadImageDataWithSize(from: archive, filename: filename)
        return result.data
    }

    private static func loadImageDataWithSize(from archive: Archive, filename: String) throws -> (data: [UInt8], width: Int, height: Int, bytesPerPixel: Int) {
        let imageData = try extractData(from: archive, filename: filename)
        let decoded = try SOGImageDecode.decodeRGBA(imageData, filename: filename)
        return (decoded.pixels, decoded.width, decoded.height, 4)
    }
}

// MARK: - Supporting Types

/// Internal metadata structure for SOGReaderCPU (different nested types than public SOGMetadata)
private struct SOGReaderCPUMetadata: Codable {
    let count: Int
    let means: MeansMetadata
    let scales: CodebookMetadata
    let quats: QuatsMetadata
    let sh0: CodebookMetadata
    let shN: SHNMetadata? // Optional higher-order spherical harmonics

    struct MeansMetadata: Codable {
        let files: [String]
        let mins: [Float]
        let maxs: [Float]
    }

    struct CodebookMetadata: Codable {
        let files: [String]
        let codebook: [Float]
    }

    struct QuatsMetadata: Codable {
        let files: [String]
    }

    /// Higher-order SH metadata (bands 1-3, stored via palette/clustering)
    struct SHNMetadata: Codable {
        let count: Int      // Number of palette entries (1-64k)
        let bands: Int      // Number of bands (1, 2, or 3)
        let codebook: [Float] // 256 floats for decoding RGB values
        let files: [String] // [centroids.webp, labels.webp]
    }
}
