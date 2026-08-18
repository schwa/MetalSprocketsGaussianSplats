import Compression
import libzstd
import Foundation
import simd
import UniformTypeIdentifiers

// MARK: - SPZReader

/// Reader for SPZ (Splat) files - a compressed format for 3D Gaussian splats
/// Supports SPZ versions 2, 3 (GZip), and 4 (NGSP / parallel ZSTD streams)
public struct SPZReader: SplatReaderProtocol {
    private let decompressedData: Data

    public let version: UInt32
    private let pointCount: UInt32
    public let shDegree: UInt8
    public let fractionalBits: UInt8
    public let isAntialiased: Bool

    private let headerSize: Int

    public var splatCount: Int {
        Int(pointCount)
    }

    public init(data: Data) throws {
        // Dispatch on the raw first four bytes: v4 files begin with plaintext
        // "NGSP"; legacy v2/v3 files begin with the GZip magic (0x1f 0x8b).
        let isNGSP = data.count >= 4 &&
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) } == 0x5053_474e

        if isNGSP {
            let parsed = try Self.parseV4(data)
            decompressedData = parsed.payload
            headerSize = 0
            version = parsed.version
            pointCount = parsed.pointCount
            shDegree = parsed.shDegree
            fractionalBits = parsed.fractionalBits
            isAntialiased = parsed.isAntialiased
        } else {
            let decompressed = try Self.decompressGzip(data)
            decompressedData = decompressed
            headerSize = 16

            guard decompressed.count >= 16 else {
                throw SplatsError.invalidHeader
            }

            let magic = decompressed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            guard magic == 0x5053_474e else {
                throw SplatsError.invalidMagic
            }

            version = decompressed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            guard version == 2 || version == 3 else {
                throw SplatsError.unsupportedVersion(version)
            }

            pointCount = decompressed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
            shDegree = decompressed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt8.self) }
            fractionalBits = decompressed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 13, as: UInt8.self) }
            let flags = decompressed.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt8.self) }
            isAntialiased = (flags & 0x1) != 0
        }

        guard shDegree <= 4 else {
            throw SplatsError.invalidSHDegree(shDegree)
        }
    }

    /// Parse an SPZ v4 (NGSP) file: read the plaintext header and TOC, ZSTD-decompress
    /// each attribute stream, and concatenate them into a single payload whose layout
    /// matches the v2/v3 in-memory format (positions, alphas, colors, scales, rotations, sh).
    private static func parseV4(
        _ data: Data
    ) throws -> (payload: Data, version: UInt32, pointCount: UInt32, shDegree: UInt8, fractionalBits: UInt8, isAntialiased: Bool) {
        guard data.count >= 32 else {
            throw SplatsError.invalidHeader
        }

        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let pointCount = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        let shDegree = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt8.self) }
        let fractionalBits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 13, as: UInt8.self) }
        let flags = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt8.self) }
        let numStreams = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 15, as: UInt8.self) })
        let tocByteOffset = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) })
        let isAntialiased = (flags & 0x1) != 0

        // TOC: numStreams entries, each two little-endian UInt64s (compressed, uncompressed).
        let tocSize = numStreams * 16
        guard tocByteOffset >= 32, tocByteOffset + tocSize <= data.count else {
            throw SplatsError.invalidHeader
        }

        // Streams follow the TOC contiguously, in write order with zero-size streams
        // omitted; concatenating them reproduces the v2/v3 payload layout exactly.
        var streamOffset = tocByteOffset + tocSize
        var payload = Data()
        for i in 0..<numStreams {
            let entry = tocByteOffset + i * 16
            let compressedSize = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entry, as: UInt64.self) })
            let uncompressedSize = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entry + 8, as: UInt64.self) })
            guard streamOffset + compressedSize <= data.count else {
                throw SplatsError.insufficientData
            }
            let compressed = data.subdata(in: streamOffset..<(streamOffset + compressedSize))
            payload.append(try decompressZstd(compressed, expectedSize: uncompressedSize))
            streamOffset += compressedSize
        }

        return (payload, version, pointCount, shDegree, fractionalBits, isAntialiased)
    }

    /// Read all splats using a callback
    public func read(_ handler: (Int, ExtendedSplat) throws -> Void) throws {
        let count = splatCount
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
            throw SplatsError.insufficientData
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

            // Convert scale from log space to actual scale
            let actualScale = SIMD3<Float>(exp(scale.x), exp(scale.y), exp(scale.z))

            // Convert color from SH DC coefficient space to 0-1 RGB
            // Using SH_C0 = 0.28209479177387814 for proper color without SH
            let SH_C0: Float = 0.28209479177387814
            let rgb = simd_clamp(color * SH_C0 + 0.5, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))

            // Convert alpha from logit space to probability using sigmoid
            let alphaProbability = 1.0 / (1.0 + exp(-alpha))

            let splat = ExtendedSplat(
                position: position,
                scale: actualScale,
                color: SIMD4<Float>(rgb.x, rgb.y, rgb.z, alphaProbability),
                rotation: rotation,
                sphericalHarmonics: sh
            )

            try handler(i, splat)
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

        // Little-endian
        let comp = byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)

        let iLargest = Int(comp >> 30)
        let cMask: UInt32 = (1 << 9) - 1

        // SPZ V3 uses XYZW order: [x, y, z, w]
        // iLargest: 0=x, 1=y, 2=z, 3=w
        var rotation = [Float](repeating: 0, count: 4)
        var sumSquares: Float = 0
        var tempComp = comp

        // Extract 3 components in DESCENDING order, skipping iLargest
        for i in stride(from: 3, through: 0, by: -1) where i != iLargest {
            let mag = tempComp & cMask
            let negbit = (tempComp >> 9) & 0x1
            tempComp = tempComp >> 10

            rotation[i] = sqrt1_2 * Float(mag) / Float(cMask)
            if negbit == 1 {
                rotation[i] = -rotation[i]
            }
            sumSquares += rotation[i] * rotation[i]
        }

        rotation[iLargest] = sqrt(1.0 - sumSquares)

        // rotation is [x, y, z, w], convert to simd_quatf
        return simd_quatf(ix: rotation[0], iy: rotation[1], iz: rotation[2], r: rotation[3])
    }

    private func unpackSphericalHarmonics(at offset: Int, coeffCount: Int) throws -> [[Float]] {
        var result: [[Float]] = []

        // SPZ SH coefficients are stored as unsigned bytes
        // Reference implementation: (float(x) - 128.0) / 128.0
        // This gives range approximately [-1, ~0.99]

        for i in 0..<coeffCount {
            var coeff = [Float](repeating: 0, count: 3)
            for channel in 0..<3 {
                let byteOffset = offset + (i * 3 + channel)
                let byte = decompressedData[byteOffset]  // UInt8
                coeff[channel] = (Float(byte) - 128.0) / 128.0
            }
            result.append(coeff)
        }

        return result
    }

    // MARK: - Helper Functions

    private func invSigmoid(_ x: Float) -> Float {
        guard x > 0, x < 1 else {
            return x
        }
        return log(x / (1.0 - x))
    }

    private func shCoefficients(for degree: UInt8) -> Int {
        switch degree {
        case 0:
            return 0
        case 1:
            return 3
        case 2:
            return 8
        case 3:
            return 15
        case 4:
            return 24
        default:
            return 0
        }
    }

    /// Decompress a single ZSTD frame into a buffer of exactly `expectedSize` bytes.
    private static func decompressZstd(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else {
            return Data()
        }
        var output = Data(count: expectedSize)
        let produced = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                ZSTD_decompress(dst.baseAddress, expectedSize, src.baseAddress, data.count)
            }
        }
        guard ZSTD_isError(produced) == 0, produced == expectedSize else {
            throw SplatsError.decompressionFailed
        }
        return output
    }

    private static func decompressGzip(_ data: Data) throws -> Data {
        guard data.count > 10 else {
            throw SplatsError.decompressionFailed
        }

        guard data[0] == 0x1f, data[1] == 0x8b else {
            throw SplatsError.decompressionFailed
        }

        var headerSize = 10
        let flags = data[3]

        if (flags & 0x04) != 0 {
            guard data.count > headerSize + 2 else { throw SplatsError.decompressionFailed }
            let xlen = Int(data[headerSize]) | (Int(data[headerSize + 1]) << 8)
            headerSize += 2 + xlen
        }

        if (flags & 0x08) != 0 {
            while headerSize < data.count, data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1
        }

        if (flags & 0x10) != 0 {
            while headerSize < data.count, data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1
        }

        if (flags & 0x02) != 0 {
            headerSize += 2
        }

        guard headerSize < data.count else {
            throw SplatsError.decompressionFailed
        }

        let compressedData = data.subdata(in: headerSize..<(data.count - 8))

        return try compressedData.withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) -> Data in
            guard let inputAddress = inputPtr.baseAddress else {
                throw SplatsError.decompressionFailed
            }

            var outputSize = compressedData.count * 10
            var outputData = Data(count: outputSize)

            var decompressedSize = 0
            repeat {
                decompressedSize = outputData.withUnsafeMutableBytes { (outputPtr: UnsafeMutableRawBufferPointer) -> Int in
                    guard let outputAddress = outputPtr.baseAddress else {
                        return 0
                    }

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
                throw SplatsError.decompressionFailed
            }

            outputData.count = decompressedSize
            return outputData
        }
    }
}
