import Foundation
import Compression
import simd

// MARK: - SPZSplat

/// Represents a 3D Gaussian splat loaded from an SPZ file
public struct SPZSplat: Equatable, Sendable {
    /// Position in 3D space (RUB coordinate system: Right-Up-Back)
    public var position: SIMD3<Float>

    /// Scale factors for the Gaussian ellipsoid
    public var scale: SIMD3<Float>

    /// RGB color (0.0 to 1.0 range)
    public var color: SIMD3<Float>

    /// Rotation as a quaternion
    public var rotation: simd_quatf

    /// Opacity/alpha value (0.0 to 1.0)
    public var alpha: Float

    /// Spherical harmonics coefficients organized as [coefficient_index][rgb_channels]
    /// - degree 0: nil (no SH)
    /// - degree 1: 3 coefficients × 3 channels = 9 values
    /// - degree 2: 8 coefficients × 3 channels = 24 values
    /// - degree 3: 15 coefficients × 3 channels = 45 values
    public var sphericalHarmonics: [[Float]]?

    public init(
        position: SIMD3<Float>,
        scale: SIMD3<Float>,
        color: SIMD3<Float>,
        rotation: simd_quatf,
        alpha: Float,
        sphericalHarmonics: [[Float]]? = nil
    ) {
        self.position = position
        self.scale = scale
        self.color = color
        self.rotation = rotation
        self.alpha = alpha
        self.sphericalHarmonics = sphericalHarmonics
    }
}

// MARK: - SPZReader

/// Reader for SPZ (Splat) files - a compressed format for 3D Gaussian splats
/// Supports both version 2 and version 3 SPZ files
public struct SPZReader {
    private let decompressedData: Data

    public let version: UInt32
    public let pointCount: UInt32
    public let shDegree: UInt8
    public let fractionalBits: UInt8
    public let isAntialiased: Bool

    private let headerSize = 16

    public init(url: URL) throws {
        let compressedData = try Data(contentsOf: url)
        try self.init(data: compressedData)
    }

    public init(data: Data) throws {
        let decompressed = try Self.decompressGzip(data)
        self.decompressedData = decompressed

        guard decompressed.count >= headerSize else {
            throw SPZError.invalidHeader
        }

        let magic = decompressed.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x5053474e else {
            throw SPZError.invalidMagic
        }

        version = decompressed.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard version == 2 || version == 3 else {
            throw SPZError.unsupportedVersion(version)
        }

        pointCount = decompressed.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        shDegree = decompressed.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt8.self) }
        fractionalBits = decompressed.withUnsafeBytes { $0.load(fromByteOffset: 13, as: UInt8.self) }
        let flags = decompressed.withUnsafeBytes { $0.load(fromByteOffset: 14, as: UInt8.self) }
        isAntialiased = (flags & 0x1) != 0

        guard shDegree <= 3 else {
            throw SPZError.invalidSHDegree(shDegree)
        }
    }

    /// Read all splats using a callback
    public func read(callback: (SPZSplat) throws -> Void) throws {
        let count = Int(pointCount)
        var offset = headerSize

        let positionsSize = count * 9
        let alphasSize = count * 1
        let colorsSize = count * 3
        let scalesSize = count * 3
        let rotationsSize = count * (version >= 3 ? 4 : 3)
        let shCoeffCount = shCoefficients(for: shDegree)
        let shSize = count * shCoeffCount * 3

        let totalSize = headerSize + positionsSize + alphasSize + colorsSize + scalesSize + rotationsSize + shSize
        guard decompressedData.count >= totalSize else {
            throw SPZError.insufficientData
        }

        let positionsOffset = offset
        offset += positionsSize

        let alphasOffset = offset
        offset += alphasSize

        let colorsOffset = offset
        offset += colorsSize

        let scalesOffset = offset
        offset += scalesSize

        let rotationsOffset = offset
        offset += rotationsSize

        let shOffset = offset

        for i in 0..<count {
            let position = try unpackPosition(at: positionsOffset + i * 9)
            let alpha = try unpackAlpha(at: alphasOffset + i)
            let color = try unpackColor(at: colorsOffset + i * 3)
            let scale = try unpackScale(at: scalesOffset + i * 3)

            let rotation: simd_quatf
            if version >= 3 {
                rotation = try unpackRotationV3(at: rotationsOffset + i * 4)
            } else {
                rotation = try unpackRotationV2(at: rotationsOffset + i * 3)
            }

            let sh = shCoeffCount > 0 ? try unpackSphericalHarmonics(at: shOffset + i * shCoeffCount * 3, coeffCount: shCoeffCount) : nil

            let splat = SPZSplat(
                position: position,
                scale: scale,
                color: color,
                rotation: rotation,
                alpha: alpha,
                sphericalHarmonics: sh
            )

            try callback(splat)
        }
    }

    // MARK: - Unpacking Functions

    private func unpackPosition(at offset: Int) throws -> SIMD3<Float> {
        var result = SIMD3<Float>()
        let scale = Float(1 << fractionalBits)

        for i in 0..<3 {
            let byteOffset = offset + i * 3
            let byte0 = UInt32(decompressedData[byteOffset])
            let byte1 = UInt32(decompressedData[byteOffset + 1])
            let byte2 = UInt32(decompressedData[byteOffset + 2])

            var fixed32 = byte0 | (byte1 << 8) | (byte2 << 16)

            if (fixed32 & 0x800000) != 0 {
                fixed32 |= 0xff000000
            }

            let signedValue = Int32(bitPattern: fixed32)
            result[i] = Float(signedValue) / scale
        }

        return result
    }

    private func unpackAlpha(at offset: Int) throws -> Float {
        let byte = decompressedData[offset]
        let normalized = Float(byte) / 255.0
        return invSigmoid(normalized)
    }

    private func unpackColor(at offset: Int) throws -> SIMD3<Float> {
        let colorScale: Float = 0.15
        var result = SIMD3<Float>()

        for i in 0..<3 {
            let byte = decompressedData[offset + i]
            result[i] = ((Float(byte) / 255.0) - 0.5) / colorScale
        }

        return result
    }

    private func unpackScale(at offset: Int) throws -> SIMD3<Float> {
        var result = SIMD3<Float>()

        for i in 0..<3 {
            let byte = decompressedData[offset + i]
            result[i] = (Float(byte) / 16.0) - 10.0
        }

        return result
    }

    private func unpackRotationV2(at offset: Int) throws -> simd_quatf {
        let x = (Float(decompressedData[offset]) / 127.5) - 1.0
        let y = (Float(decompressedData[offset + 1]) / 127.5) - 1.0
        let z = (Float(decompressedData[offset + 2]) / 127.5) - 1.0
        let w = sqrt(max(0.0, 1.0 - (x * x + y * y + z * z)))

        return simd_quatf(ix: x, iy: y, iz: z, r: w)
    }

    private func unpackRotationV3(at offset: Int) throws -> simd_quatf {
        let sqrt1_2: Float = 0.707106781186547524401

        let byte0 = UInt32(decompressedData[offset])
        let byte1 = UInt32(decompressedData[offset + 1])
        let byte2 = UInt32(decompressedData[offset + 2])
        let byte3 = UInt32(decompressedData[offset + 3])

        let comp = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)

        let iLargest = Int(comp >> 30)
        let cMask: UInt32 = (1 << 9) - 1

        var rotation = [Float](repeating: 0, count: 4)
        var sumSquares: Float = 0
        var tempComp = comp

        for i in (0...3).reversed() {
            if i != iLargest {
                let mag = tempComp & cMask
                let negbit = (tempComp >> 9) & 0x1
                tempComp = tempComp >> 10

                rotation[i] = sqrt1_2 * Float(mag) / Float(cMask)
                if negbit == 1 {
                    rotation[i] = -rotation[i]
                }
                sumSquares += rotation[i] * rotation[i]
            }
        }

        rotation[iLargest] = sqrt(1.0 - sumSquares)

        return simd_quatf(ix: rotation[0], iy: rotation[1], iz: rotation[2], r: rotation[3])
    }

    private func unpackSphericalHarmonics(at offset: Int, coeffCount: Int) throws -> [[Float]] {
        var result: [[Float]] = []

        for i in 0..<coeffCount {
            var coeff = [Float](repeating: 0, count: 3)
            for channel in 0..<3 {
                let byteOffset = offset + (i * 3 + channel)
                let byte = Int8(bitPattern: decompressedData[byteOffset])
                coeff[channel] = (Float(byte) + 128.0) / 128.0
            }
            result.append(coeff)
        }

        return result
    }

    // MARK: - Helper Functions

    private func invSigmoid(_ x: Float) -> Float {
        guard x > 0 && x < 1 else { return x }
        return log(x / (1.0 - x))
    }

    private func shCoefficients(for degree: UInt8) -> Int {
        switch degree {
        case 0: return 0
        case 1: return 3
        case 2: return 8
        case 3: return 15
        default: return 0
        }
    }

    private static func decompressGzip(_ data: Data) throws -> Data {
        guard data.count > 10 else {
            throw SPZError.decompressionFailed
        }

        guard data[0] == 0x1f && data[1] == 0x8b else {
            throw SPZError.decompressionFailed
        }

        var headerSize = 10
        let flags = data[3]

        if (flags & 0x04) != 0 {
            guard data.count > headerSize + 2 else { throw SPZError.decompressionFailed }
            let xlen = Int(data[headerSize]) | (Int(data[headerSize + 1]) << 8)
            headerSize += 2 + xlen
        }

        if (flags & 0x08) != 0 {
            while headerSize < data.count && data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1
        }

        if (flags & 0x10) != 0 {
            while headerSize < data.count && data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1
        }

        if (flags & 0x02) != 0 {
            headerSize += 2
        }

        guard headerSize < data.count else {
            throw SPZError.decompressionFailed
        }

        let compressedData = data.subdata(in: headerSize..<(data.count - 8))

        let decompressed = try compressedData.withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) -> Data in
            guard let inputAddress = inputPtr.baseAddress else {
                throw SPZError.decompressionFailed
            }

            var outputSize = compressedData.count * 10
            var outputData = Data(count: outputSize)

            var decompressedSize = 0
            repeat {
                decompressedSize = outputData.withUnsafeMutableBytes { (outputPtr: UnsafeMutableRawBufferPointer) -> Int in
                    guard let outputAddress = outputPtr.baseAddress else { return 0 }

                    return compression_decode_buffer(
                        outputAddress,
                        outputSize,
                        inputAddress,
                        compressedData.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }

                if decompressedSize == 0 {
                    outputSize *= 2
                    outputData = Data(count: outputSize)
                } else {
                    break
                }
            } while decompressedSize == 0 && outputSize < compressedData.count * 100

            guard decompressedSize > 0 else {
                throw SPZError.decompressionFailed
            }

            outputData.count = decompressedSize
            return outputData
        }

        return decompressed
    }
}

// MARK: - Error Types

public enum SPZError: Error, Equatable {
    case decompressionFailed
    case invalidHeader
    case invalidMagic
    case unsupportedVersion(UInt32)
    case invalidSHDegree(UInt8)
    case insufficientData
}
