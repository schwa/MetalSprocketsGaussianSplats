import CoreGraphics
import Foundation
import ImageIO
import MetalSprocketsGaussianSplatShaders
import simd
import ZIPFoundation

// MARK: - SOGReaderCPU

/// Reader for SOG (Splat Optimized GPU) files
/// Uses CPU-based conversion
public struct SOGReaderCPU: SplatReader {
    private let splats: [GenericSplat]

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

        self.splats = try Self.loadSplats(from: tempURL)
    }

    /// Load SOG file from URL
    public init(url: URL) throws {
        self.splats = try Self.loadSplats(from: url)
    }

    public func read(_ handler: (Int, GenericSplat) throws -> Void) throws {
        for (index, splat) in splats.enumerated() {
            try handler(index, splat)
        }
    }

    // MARK: - Private

    private static func loadSplats(from url: URL) throws -> [GenericSplat] {
        // Open archive
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw SOGError.failedToExtractZIP
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

        // Extract mins/maxs from metadata
        let mins = SIMD3<Float>(metadata.means.mins[0], metadata.means.mins[1], metadata.means.mins[2])
        let maxs = SIMD3<Float>(metadata.means.maxs[0], metadata.means.maxs[1], metadata.means.maxs[2])

        // Convert to splats
        var splats = [GenericSplat]()
        splats.reserveCapacity(metadata.count)

        let scalesCodebook = metadata.scales.codebook
        let sh0Codebook = metadata.sh0.codebook

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
        }

        return splats
    }

    private static func extractData(from archive: Archive, filename: String) throws -> Data {
        guard let entry = archive[filename] else {
            throw SOGError.missingTexture(filename)
        }

        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func loadImageData(from archive: Archive, filename: String) throws -> [UInt8] {
        let imageData = try extractData(from: archive, filename: filename)

        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw SOGError.failedToDecodeImage(filename)
        }

        let width = cgImage.width
        let height = cgImage.height
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
            throw SOGError.failedToDecodeImage(filename)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixelData
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
}

// MARK: - Error Types

public enum SOGError: Error, Equatable {
    case failedToExtractZIP
    case missingMetadata
    case failedToDecodeMetadata
    case missingTexture(String)
    case failedToDecodeImage(String)
    case failedToCreateTexture(String)
    case failedToCreateBuffer
}
