#import <simd/simd.h>

// Helper structures and functions for Spark splat rendering

// Constants
#define SPARK_LN_SCALE_MIN -12.0
#define SPARK_LN_SCALE_MAX 9.0
#define SPARK_LN_SCALE_INV_SCALE ((SPARK_LN_SCALE_MAX - SPARK_LN_SCALE_MIN) / 254.0)

#ifdef __METAL_VERSION__
// Metal-only inline functions

#import <metal_stdlib>

namespace SparkSplatSupport {
    using namespace metal;

    // MARK: - Float16 Conversion

    inline float halfToFloat(ushort h) {
        uint sign = uint(h & 0x8000) << 16;
        uint exponent = (h >> 10) & 0x1F;
        uint mantissa = uint(h & 0x3FF);

        if (exponent == 0) {
            if (mantissa == 0) {
                return as_type<float>(sign);  // Zero
            }
            // Denormalized
            uint exp = 127 - 14;
            uint mant = mantissa << 13;
            return as_type<float>(sign | (exp << 23) | mant);
        } else if (exponent == 31) {
            // Infinity or NaN
            return as_type<float>(sign | 0x7F800000 | (mantissa << 13));
        } else {
            // Normalized
            uint exp = exponent - 15 + 127;
            uint mant = mantissa << 13;
            return as_type<float>(sign | (exp << 23) | mant);
        }
    }

    // MARK: - Scale Decoding

    inline float decodeLogScale(uchar uScale) {
        if (uScale == 0) {
            return 0.0;  // 2DGS marker
        }
        float lnScale = SPARK_LN_SCALE_MIN + float(uScale - 1) * SPARK_LN_SCALE_INV_SCALE;
        return exp(lnScale);
    }

    // MARK: - Quaternion Math

    /// Rotate vector by quaternion
    inline float3 quatVec(float4 q, float3 v) {
        float3 t = 2.0 * cross(q.xyz, v);
        return v + q.w * t + cross(q.xyz, t);
    }

    /// Multiply two quaternions
    inline float4 quatQuat(float4 q1, float4 q2) {
        return float4(
            q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
            q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
            q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w,
            q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z
        );
    }

    /// Build rotation-scale matrix from scale vector and quaternion
    inline float3x3 scaleQuaternionToMatrix(float3 s, float4 q) {
        return float3x3(
            s.x * (1.0 - 2.0 * (q.y * q.y + q.z * q.z)),
            s.x * (2.0 * (q.x * q.y + q.w * q.z)),
            s.x * (2.0 * (q.x * q.z - q.w * q.y)),

            s.y * (2.0 * (q.x * q.y - q.w * q.z)),
            s.y * (1.0 - 2.0 * (q.x * q.x + q.z * q.z)),
            s.y * (2.0 * (q.y * q.z + q.w * q.x)),

            s.z * (2.0 * (q.x * q.z + q.w * q.y)),
            s.z * (2.0 * (q.y * q.z - q.w * q.x)),
            s.z * (1.0 - 2.0 * (q.x * q.x + q.y * q.y))
        );
    }

    // MARK: - Quaternion Decoding

    /// Decode octahedral quaternion from 24 bits
    inline float4 decodeQuatOctXy88R8(uint encoded) {
        uchar quantU = uchar(encoded & 0xFF);
        uchar quantV = uchar((encoded >> 8) & 0xFF);
        uchar angleInt = uchar((encoded >> 16) & 0xFF);

        // Dequantize
        float u = float(quantU) / 255.0;
        float v = float(quantV) / 255.0;
        float theta = float(angleInt) / 255.0 * M_PI_F;

        // Reverse octahedral mapping
        float2 f = float2(u * 2.0 - 1.0, v * 2.0 - 1.0);
        float z = 1.0 - abs(f.x) - abs(f.y);

        // Unfold if needed
        if (z < 0.0) {
            float t = max(-z, 0.0);
            f.x += (f.x >= 0.0 ? -t : t);
            f.y += (f.y >= 0.0 ? -t : t);
        }

        // Normalize to get axis
        float3 axis = normalize(float3(f.x, f.y, z));

        // Reconstruct quaternion
        float halfTheta = theta / 2.0;
        float sinHalfTheta = sin(halfTheta);
        float cosHalfTheta = cos(halfTheta);

        return float4(
            axis.x * sinHalfTheta,
            axis.y * sinHalfTheta,
            axis.z * sinHalfTheta,
            cosHalfTheta
        );
    }

    // MARK: - Splat Unpacking

    /// Unpack Spark splat from packed format
    inline void unpackSplatEncoding(
        uint4 packed,
        thread float3& center,
        thread float3& scales,
        thread float4& quaternion,
        thread float4& rgba
    ) {
        // Word 0: RGBA
        rgba = float4(
            float(packed.x & 0xFF),
            float((packed.x >> 8) & 0xFF),
            float((packed.x >> 16) & 0xFF),
            float((packed.x >> 24) & 0xFF)
        ) / 255.0;

        // Word 1: centerX, centerY (float16)
        float centerX = halfToFloat(ushort(packed.y & 0xFFFF));
        float centerY = halfToFloat(ushort((packed.y >> 16) & 0xFFFF));

        // Word 2: centerZ (float16), quatX, quatY (uint8)
        float centerZ = halfToFloat(ushort(packed.z & 0xFFFF));
        uchar quatX = uchar((packed.z >> 16) & 0xFF);
        uchar quatY = uchar((packed.z >> 24) & 0xFF);

        center = float3(centerX, centerY, centerZ);

        // Word 3: scaleX, scaleY, scaleZ, quatZ (uint8)
        uchar scaleX = uchar(packed.w & 0xFF);
        uchar scaleY = uchar((packed.w >> 8) & 0xFF);
        uchar scaleZ = uchar((packed.w >> 16) & 0xFF);
        uchar quatZ = uchar((packed.w >> 24) & 0xFF);

        scales = float3(
            decodeLogScale(scaleX),
            decodeLogScale(scaleY),
            decodeLogScale(scaleZ)
        );

        // Decode quaternion
        uint quatEncoded = uint(quatX) | (uint(quatY) << 8) | (uint(quatZ) << 16);
        quaternion = decodeQuatOctXy88R8(quatEncoded);
    }

}

#endif // __METAL_VERSION__
