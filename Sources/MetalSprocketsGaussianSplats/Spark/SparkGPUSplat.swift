import Foundation
import simd

/// Spark GPU Splat - 16 byte packed format
/// Word 0: RGBA (4x uint8)
/// Word 1: centerX, centerY (2x float16)
/// Word 2: centerZ (float16), quatX, quatY (2x uint8)
/// Word 3: scaleX, scaleY, scaleZ, quatZ (4x uint8)
public struct SparkGPUSplat {
    public var packed: SIMD4<UInt32>

    // MARK: - Constants

    private static let LN_SCALE_MIN: Float = -12.0
    private static let LN_SCALE_MAX: Float = 9.0
    private static let LN_SCALE_SCALE = 254.0 / (LN_SCALE_MAX - LN_SCALE_MIN)  // ~12.095
    private static let LN_SCALE_INV_SCALE = (LN_SCALE_MAX - LN_SCALE_MIN) / 254.0  // ~0.0827
    private static let SCALE_ZERO_THRESHOLD: Float = 0.0000001  // exp(-30)

    // MARK: - Initialization

    public init(packed: SIMD4<UInt32>) {
        self.packed = packed
    }

    public init(position: SIMD3<Float>, scale: SIMD3<Float>, quaternion: simd_quatf, color: SIMD4<UInt8>) {
        // Word 0: RGBA
        let word0 = UInt32(color.x)
            | (UInt32(color.y) << 8)
            | (UInt32(color.z) << 16)
            | (UInt32(color.w) << 24)

        // Word 1: centerX, centerY as float16
        let centerX = Self.floatToHalf(position.x)
        let centerY = Self.floatToHalf(position.y)
        let word1 = UInt32(centerX) | (UInt32(centerY) << 16)

        // Word 2: centerZ as float16, quatX, quatY as uint8
        let centerZ = Self.floatToHalf(position.z)
        let quatEncoded = Self.encodeQuatOctXy88R8(quaternion)
        let quatX = UInt8(quatEncoded & 0xFF)
        let quatY = UInt8((quatEncoded >> 8) & 0xFF)
        let word2 = UInt32(centerZ) | (UInt32(quatX) << 16) | (UInt32(quatY) << 24)

        // Word 3: scaleX, scaleY, scaleZ, quatZ as uint8
        let scaleX = Self.encodeLogScale(scale.x)
        let scaleY = Self.encodeLogScale(scale.y)
        let scaleZ = Self.encodeLogScale(scale.z)
        let quatZ = UInt8((quatEncoded >> 16) & 0xFF)
        let word3 = UInt32(scaleX) | (UInt32(scaleY) << 8) | (UInt32(scaleZ) << 16) | (UInt32(quatZ) << 24)

        self.packed = SIMD4<UInt32>(word0, word1, word2, word3)
    }

    // MARK: - Unpacking (for debugging/testing)

    public var position: SIMD3<Float> {
        let centerX = Self.halfToFloat(UInt16(packed.y & 0xFFFF))
        let centerY = Self.halfToFloat(UInt16((packed.y >> 16) & 0xFFFF))
        let centerZ = Self.halfToFloat(UInt16(packed.z & 0xFFFF))
        return SIMD3<Float>(centerX, centerY, centerZ)
    }

    public var color: SIMD4<UInt8> {
        return SIMD4<UInt8>(
            UInt8(packed.x & 0xFF),
            UInt8((packed.x >> 8) & 0xFF),
            UInt8((packed.x >> 16) & 0xFF),
            UInt8((packed.x >> 24) & 0xFF)
        )
    }

    public var scale: SIMD3<Float> {
        let scaleX = Self.decodeLogScale(UInt8(packed.w & 0xFF))
        let scaleY = Self.decodeLogScale(UInt8((packed.w >> 8) & 0xFF))
        let scaleZ = Self.decodeLogScale(UInt8((packed.w >> 16) & 0xFF))
        return SIMD3<Float>(scaleX, scaleY, scaleZ)
    }

    public var quaternion: simd_quatf {
        let quatX = UInt8((packed.z >> 16) & 0xFF)
        let quatY = UInt8((packed.z >> 24) & 0xFF)
        let quatZ = UInt8((packed.w >> 24) & 0xFF)
        let encoded = UInt32(quatX) | (UInt32(quatY) << 8) | (UInt32(quatZ) << 16)
        return Self.decodeQuatOctXy88R8(encoded)
    }

    // MARK: - Float16 Encoding/Decoding

    /// Convert float32 to float16 (IEEE 754)
    private static func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = (bits >> 16) & 0x8000
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = (bits >> 13) & 0x3FF

        // Handle special cases
        if exponent <= 0 {
            // Underflow to zero
            return UInt16(sign)
        } else if exponent >= 31 {
            // Overflow to infinity
            return UInt16(sign | 0x7C00)
        }

        return UInt16(sign | (UInt32(exponent) << 10) | mantissa)
    }

    /// Convert float16 to float32 (IEEE 754)
    private static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exponent = Int((h >> 10) & 0x1F)
        let mantissa = UInt32(h & 0x3FF)

        if exponent == 0 {
            // Zero or denormalized
            if mantissa == 0 {
                return Float(bitPattern: sign)  // Zero
            }
            // Denormalized - convert to normalized float32
            let exp: UInt32 = 127 - 14
            let mant = mantissa << 13
            return Float(bitPattern: sign | (exp << 23) | mant)
        } else if exponent == 31 {
            // Infinity or NaN
            return Float(bitPattern: sign | 0x7F800000 | (mantissa << 13))
        } else {
            // Normalized - do arithmetic in Int space to avoid underflow
            let exp = UInt32(exponent - 15 + 127)
            let mant = mantissa << 13
            return Float(bitPattern: sign | (exp << 23) | mant)
        }
    }

    // MARK: - Logarithmic Scale Encoding/Decoding

    /// Encode scale to uint8 using logarithmic encoding
    /// Range: e^-12 to e^9 (0.0001 to 8000)
    /// Value 0 is reserved for 2DGS (zero thickness)
    private static func encodeLogScale(_ scale: Float) -> UInt8 {
        if scale < SCALE_ZERO_THRESHOLD {
            return 0  // 2DGS marker
        }
        let lnScale = log(scale)
        let encoded = (lnScale - LN_SCALE_MIN) * LN_SCALE_SCALE + 1.0
        return UInt8(min(255, max(1, Int(encoded.rounded()))))
    }

    /// Decode uint8 to scale using logarithmic decoding
    private static func decodeLogScale(_ uScale: UInt8) -> Float {
        if uScale == 0 {
            return 0.0  // 2DGS (zero thickness)
        }
        let lnScale = LN_SCALE_MIN + Float(uScale - 1) * LN_SCALE_INV_SCALE
        return exp(lnScale)
    }

    // MARK: - Octahedral Quaternion Encoding/Decoding

    /// Encode quaternion to 24 bits using folded octahedral mapping
    /// Returns: (quatX | quatY << 8 | quatZ << 16)
    private static func encodeQuatOctXy88R8(_ q: simd_quatf) -> UInt32 {
        var quat = q

        // Normalize
        quat = simd_normalize(quat)

        // Ensure w >= 0 (quaternions q and -q represent same rotation)
        if quat.vector.w < 0 {
            quat = simd_quatf(ix: -quat.imag.x, iy: -quat.imag.y, iz: -quat.imag.z, r: -quat.real)
        }

        // Compute rotation angle theta in [0, pi]
        let theta = 2.0 * acos(min(1.0, abs(quat.real)))

        // Extract rotation axis
        var axis: SIMD3<Float>
        if theta < 0.0001 {
            axis = SIMD3<Float>(1, 0, 0)  // Default axis for near-zero rotation
        } else {
            let sinHalfTheta = sin(theta / 2.0)
            axis = quat.imag / sinHalfTheta
            axis = simd_normalize(axis)
        }

        // Folded octahedral mapping
        let absSum = abs(axis.x) + abs(axis.y) + abs(axis.z)
        var p = SIMD2<Float>(axis.x / absSum, axis.y / absSum)

        // Fold if z < 0
        if axis.z < 0 {
            let signX: Float = p.x >= 0 ? 1 : -1
            let signY: Float = p.y >= 0 ? 1 : -1
            p = SIMD2<Float>(
                (1.0 - abs(p.y)) * signX,
                (1.0 - abs(p.x)) * signY
            )
        }

        // Remap to [0, 1]
        let u = p.x * 0.5 + 0.5
        let v = p.y * 0.5 + 0.5

        // Quantize to 8 bits each
        let quantU = UInt8(min(255, max(0, Int((u * 255.0).rounded()))))
        let quantV = UInt8(min(255, max(0, Int((v * 255.0).rounded()))))
        let angleInt = UInt8(min(255, max(0, Int((theta / Float.pi * 255.0).rounded()))))

        return UInt32(quantU) | (UInt32(quantV) << 8) | (UInt32(angleInt) << 16)
    }

    /// Decode 24 bits to quaternion using folded octahedral mapping
    private static func decodeQuatOctXy88R8(_ encoded: UInt32) -> simd_quatf {
        let quantU = UInt8(encoded & 0xFF)
        let quantV = UInt8((encoded >> 8) & 0xFF)
        let angleInt = UInt8((encoded >> 16) & 0xFF)

        // Dequantize
        let u = Float(quantU) / 255.0
        let v = Float(quantV) / 255.0
        let theta = Float(angleInt) / 255.0 * Float.pi

        // Reverse octahedral mapping
        var f = SIMD2<Float>(u * 2.0 - 1.0, v * 2.0 - 1.0)
        let z = 1.0 - abs(f.x) - abs(f.y)

        // Unfold if needed
        if z < 0 {
            let t = max(-z, 0.0)
            f.x += (f.x >= 0 ? -t : t)
            f.y += (f.y >= 0 ? -t : t)
        }

        // Normalize to get axis
        var axis = SIMD3<Float>(f.x, f.y, z)
        axis = simd_normalize(axis)

        // Reconstruct quaternion: q = (axis * sin(theta/2), cos(theta/2))
        let halfTheta = theta / 2.0
        let sinHalfTheta = sin(halfTheta)
        let cosHalfTheta = cos(halfTheta)

        return simd_quatf(
            ix: axis.x * sinHalfTheta,
            iy: axis.y * sinHalfTheta,
            iz: axis.z * sinHalfTheta,
            r: cosHalfTheta
        )
    }
}

// MARK: - SortableSplatProtocol Conformance

extension SparkGPUSplat: SortableSplatProtocol {
    public var floatPosition: SIMD3<Float> {
        return position
    }
}
