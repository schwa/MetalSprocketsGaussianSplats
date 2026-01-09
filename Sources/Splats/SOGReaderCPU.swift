import CoreGraphics
import Foundation
import ImageIO
import simd
import ZIPFoundation

// MARK: - SOGReaderCPU

/// Reader for SOG (Splat Optimized GPU) files
/// Uses CPU-based conversion
public struct SOGReaderCPU: SplatReader {
    private let splats: [GenericSplat]
    private let sphericalHarmonics: [[[Float]]]? // Per-splat SH coefficients, or nil if no SH data. Each splat has [[r,g,b], [r,g,b], ...]
    
    /// The degree of spherical harmonics (0 = none, 1-3 = higher-order SH)
    public let shDegree: Int

    public var splatCount: Int {
        splats.count
    }

    /// Load SOG data
    public init(data: Data) throws {
        // Write data to temp file since we need URL for ZIP extraction
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
        self.shDegree = result.shDegree
    }

    /// Load SOG file from URL
    public init(url: URL) throws {
        let result = try Self.loadSplats(from: url)
        self.splats = result.splats
        self.sphericalHarmonics = result.sphericalHarmonics
        self.shDegree = result.shDegree
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
        // Open archive
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw SplatsError.failedToExtractZIP
        }

        // Load metadata
        let metadataData = try extractData(from: archive, filename: "meta.json")
        let metadata = try JSONDecoder().decode(SOGReaderCPUMetadata.self, from: metadataData)

        // Load image data directly from archive
        let meansLowData = try loadImageData(from: archive, filename: metadata.means.files[0])
        let meansHighData = try loadImageData(from: archive, filename: metadata.means.files[1])
        let scalesData = try loadImageData(from: archive, filename: metadata.scales.files[0])
        let quatsData = try loadImageData(from: archive, filename: metadata.quats.files[0])
        let sh0Data = try loadImageData(from: archive, filename: metadata.sh0.files[0])

        // Load higher-order SH data if present
        var shCentroids: [UInt8]?
        var shLabels: [UInt8]?
        var shCentroidsWidth: Int = 0
        if let shN = metadata.shN, shN.files.count >= 2 {
            let centroidsResult = try loadImageDataWithSize(from: archive, filename: shN.files[0])
            shCentroids = centroidsResult.data
            shCentroidsWidth = centroidsResult.width
            shLabels = try loadImageData(from: archive, filename: shN.files[1])
        }

        // Extract mins/maxs from metadata
        let mins = SIMD3<Float>(metadata.means.mins[0], metadata.means.mins[1], metadata.means.mins[2])
        let maxs = SIMD3<Float>(metadata.means.maxs[0], metadata.means.maxs[1], metadata.means.maxs[2])

        // Convert to splats
        var splats = [GenericSplat]()
        splats.reserveCapacity(metadata.count)

        // Prepare SH storage if we have higher-order SH
        var sphericalHarmonics: [[[Float]]]? // [splat][coefficient][rgb]
        var shDegree = 0
        if metadata.shN != nil, shCentroids != nil, shLabels != nil {
            shDegree = metadata.shN!.bands // bands 1-3 correspond to degree 1-3
            sphericalHarmonics = []
            sphericalHarmonics?.reserveCapacity(metadata.count)
        }

        let scalesCodebook = metadata.scales.codebook
        let sh0Codebook = metadata.sh0.codebook

        // Number of coefficients per band (excluding DC/SH0):
        // Band 1 (degree 1): 3 coefficients
        // Band 2 (degree 2): 5 coefficients (total 8 for bands 1-2)
        // Band 3 (degree 3): 7 coefficients (total 15 for bands 1-3)
        let coeffsPerBand = [3, 8, 15]

        for i in 0..<metadata.count {
            let offset = i * 4

            // Position from means textures
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

            // Scale from codebook (each channel is a separate index)
            let scaleXIndex = Int(scalesData[offset])
            let scaleYIndex = Int(scalesData[offset + 1])
            let scaleZIndex = Int(scalesData[offset + 2])
            let scale = SIMD3<Float>(
                exp(scalesCodebook[scaleXIndex]),
                exp(scalesCodebook[scaleYIndex]),
                exp(scalesCodebook[scaleZIndex])
            )

            // Rotation from texture
            let qx = (Float(quatsData[offset]) / 255.0) * 2.0 - 1.0
            let qy = (Float(quatsData[offset + 1]) / 255.0) * 2.0 - 1.0
            let qz = (Float(quatsData[offset + 2]) / 255.0) * 2.0 - 1.0
            let qw = (Float(quatsData[offset + 3]) / 255.0) * 2.0 - 1.0
            let rotation = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw).normalized

            // Color from SH0 codebook
            // Each RGB channel byte is a direct index into the 256-value codebook
            let SH_C0: Float = 0.28209479177387814
            let rIndex = Int(sh0Data[offset])
            let gIndex = Int(sh0Data[offset + 1])
            let bIndex = Int(sh0Data[offset + 2])
            let r = max(0, min(1, sh0Codebook[rIndex] * SH_C0 + 0.5))
            let g = max(0, min(1, sh0Codebook[gIndex] * SH_C0 + 0.5))
            let b = max(0, min(1, sh0Codebook[bIndex] * SH_C0 + 0.5))

            // Alpha from texture alpha channel
            let alpha = Float(sh0Data[offset + 3]) / 255.0

            let splat = GenericSplat(
                position: position,
                scale: scale,
                color: SIMD4<Float>(r, g, b, alpha),
                rotation: rotation
            )
            splats.append(splat)

            // Extract higher-order SH coefficients if present
            if let shN = metadata.shN, let centroids = shCentroids, let labels = shLabels {
                let numCoeffs = coeffsPerBand[shN.bands - 1]

                // Get 16-bit palette index from labels (R + G << 8)
                let paletteIndex = Int(labels[offset]) + (Int(labels[offset + 1]) << 8)

                // Look up SH coefficients from centroids palette
                // Palette layout: 64 entries per row, each entry has numCoeffs pixels (RGB per pixel)
                // For palette entry n and coefficient c:
                //   u = (n % 64) * numCoeffs + c
                //   v = n / 64
                let entriesPerRow = 64
                let paletteU = (paletteIndex % entriesPerRow) * numCoeffs
                let paletteV = paletteIndex / entriesPerRow

                var shCoeffs = [[Float]]()
                shCoeffs.reserveCapacity(numCoeffs)

                // Read each coefficient (each is an RGB pixel in the centroids texture)
                for c in 0..<numCoeffs {
                    let pixelX = paletteU + c
                    let pixelY = paletteV
                    let pixelOffset = (pixelY * shCentroidsWidth + pixelX) * 4 // RGBA

                    // RGB values are indices into the shN codebook
                    let rIdx = Int(centroids[pixelOffset])
                    let gIdx = Int(centroids[pixelOffset + 1])
                    let bIdx = Int(centroids[pixelOffset + 2])

                    // Look up actual SH values from codebook
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

        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw SplatsError.failedToDecodeImage(filename)
        }

        let width = cgImage.width
        let height = cgImage.height

        // Always decode to RGBA for consistency
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SplatsError.failedToDecodeImage(filename)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return (pixelData, width, height, 4)
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
