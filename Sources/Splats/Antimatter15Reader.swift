import Foundation
import simd
import UniformTypeIdentifiers

public extension UTType {
    static var antimatter15Splat: UTType {
        guard let type = UTType(filenameExtension: "splat") else {
            fatalError("Failed to create UTType for .splat extension")
        }
        return type
    }
}

// MARK: - Antimatter15Reader

/// Reader for .splat files - the Antimatter15 format for 3D Gaussian splats
/// Each splat is 32 bytes: position (12), scale (12), color (4), rotation (4)
public struct Antimatter15Reader: SplatReader {
    private let data: Data

    public var splatCount: Int {
        data.count / 32
    }

    public init(data: Data) throws {
        guard data.count.isMultiple(of: 32) else {
            throw Antimatter15Error.invalidFileSize
        }
        self.data = data
    }

    /// Read all splats using a callback
    public func read(_ handler: (Int, GenericSplat) throws -> Void) throws {
        for i in 0..<splatCount {
            let offset = i * 32

            // Read position (3 floats, 12 bytes)
            let px = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 0, as: Float.self) }
            let py = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: Float.self) }
            let pz = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 8, as: Float.self) }
            let position = SIMD3<Float>(px, py, pz)

            // Read scale (3 floats, 12 bytes)
            let sx = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 12, as: Float.self) }
            let sy = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 16, as: Float.self) }
            let sz = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 20, as: Float.self) }
            let scale = SIMD3<Float>(sx, sy, sz)

            // Read color (4 UInt8, 4 bytes) - convert to 0-1 range
            let r = Float(data[offset + 24]) / 255.0
            let g = Float(data[offset + 25]) / 255.0
            let b = Float(data[offset + 26]) / 255.0
            let a = Float(data[offset + 27]) / 255.0
            let color = SIMD4<Float>(r, g, b, a)

            // Read rotation (4 UInt8, 4 bytes) - XYZW order
            let rotX = (Float(data[offset + 28]) - 128.0) / 128.0
            let rotY = (Float(data[offset + 29]) - 128.0) / 128.0
            let rotZ = (Float(data[offset + 30]) - 128.0) / 128.0
            let rotW = (Float(data[offset + 31]) - 128.0) / 128.0
            let rotation = simd_quatf(ix: rotX, iy: rotY, iz: rotZ, r: rotW)

            let splat = GenericSplat(
                position: position,
                scale: scale,
                color: color,
                rotation: rotation
            )

            try handler(i, splat)
        }
    }
}

// MARK: - Error Types

public enum Antimatter15Error: Error, Equatable {
    case invalidFileSize
}
