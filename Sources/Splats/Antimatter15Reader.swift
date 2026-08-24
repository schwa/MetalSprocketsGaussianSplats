import Foundation
import simd

public struct Antimatter15Reader: SplatReaderProtocol {
    private static let recordSize = 32
    private let data: Data

    public var splatCount: Int { data.count / Self.recordSize }

    public init(data: Data) throws {
        guard data.count.isMultiple(of: Self.recordSize) else {
            throw SplatsError.invalidData
        }
        self.data = data
    }

    public func read(_ handler: (Int, ExtendedSplat) throws -> Void) throws {
        try data.withUnsafeBytes { bytes in
            for index in 0..<splatCount {
                let offset = index * Self.recordSize
                let position = SIMD3<Float>(
                    bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                )
                let scale = SIMD3<Float>(
                    bytes.loadUnaligned(fromByteOffset: offset + 12, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: offset + 16, as: Float.self),
                    bytes.loadUnaligned(fromByteOffset: offset + 20, as: Float.self)
                )
                let color = SIMD4<Float>(
                    Float(bytes[offset + 24]) / 255,
                    Float(bytes[offset + 25]) / 255,
                    Float(bytes[offset + 26]) / 255,
                    Float(bytes[offset + 27]) / 255
                )
                let rotation = simd_quatf(
                    ix: (Float(bytes[offset + 29]) - 128) / 128,
                    iy: (Float(bytes[offset + 30]) - 128) / 128,
                    iz: (Float(bytes[offset + 31]) - 128) / 128,
                    r: (Float(bytes[offset + 28]) - 128) / 128
                )
                try handler(index, ExtendedSplat(position: position, scale: scale, color: color, rotation: rotation))
            }
        }
    }
}
