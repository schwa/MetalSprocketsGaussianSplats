#import <simd/simd.h>

#ifdef __METAL_VERSION__

#import <metal_stdlib>

namespace SOGSplatSupport {
    using namespace metal;

    // Inverse log transform: sign(x) * (exp(|x|) - 1)
    inline float invLogTransform(float v) {
        float a = abs(v);
        float e = exp(a) - 1.0;
        return v < 0.0 ? -e : e;
    }

    // Decode position from two textures (low and high bytes)
    inline float3 decodePosition(
        uint2 texCoord,
        texture2d<float, access::read> meansLow,
        texture2d<float, access::read> meansHigh,
        float3 mins,
        float3 maxs
    ) {
        float4 lo = meansLow.read(texCoord);
        float4 hi = meansHigh.read(texCoord);

        // Combine upper and lower bytes: (upper << 8) | lower
        uint3 raw = uint3(
            (uint(hi.r * 255.0) << 8) | uint(lo.r * 255.0),
            (uint(hi.g * 255.0) << 8) | uint(lo.g * 255.0),
            (uint(hi.b * 255.0) << 8) | uint(lo.b * 255.0)
        );

        // Normalize to [0, 1] and apply bounds (lerp in log domain)
        float3 t = float3(raw) / 65535.0;
        float3 logPos = mins + t * (maxs - mins);

        // Apply inverse log transform
        return float3(
            invLogTransform(logPos.x),
            invLogTransform(logPos.y),
            invLogTransform(logPos.z)
        );
    }

    // Decode scales from texture using codebook (values are log-transformed)
    inline float3 decodeScales(
        uint2 texCoord,
        texture2d<float, access::read> scalesTex,
        constant float* codebook
    ) {
        float4 indices = scalesTex.read(texCoord);
        // Codebook contains log(scale), so apply exp()
        return float3(
            exp(codebook[uint(indices.r * 255.0)]),
            exp(codebook[uint(indices.g * 255.0)]),
            exp(codebook[uint(indices.b * 255.0)])
        );
    }

    // Decode quaternion from SOG format (smallest-three encoding)
    inline float4 decodeQuaternion(uint2 texCoord, texture2d<float, access::read> quatsTex) {
        float4 packed = quatsTex.read(texCoord);

        uchar tag = uchar(packed.a * 255.0);

        // Tag 252-255 indicates mode (which component was omitted)
        int mode = tag - 252;
        if (mode < 0 || mode > 3) {
            // Invalid tag, return identity quaternion
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        // Dequantize the stored three components to [-sqrt(2)/2, +sqrt(2)/2]
        float sqrt2 = sqrt(2.0);
        float a = (packed.r - 0.5) * 2.0 / sqrt2;
        float b = (packed.g - 0.5) * 2.0 / sqrt2;
        float c = (packed.b - 0.5) * 2.0 / sqrt2;

        // Reconstruct the omitted component so ||q|| = 1
        float t = a * a + b * b + c * c;
        float d = sqrt(max(0.0, 1.0 - t));

        // Place components according to mode
        // mode 0: omitted = x, q = [d, a, b, c]
        // mode 1: omitted = y, q = [a, d, b, c]
        // mode 2: omitted = z, q = [a, b, d, c]
        // mode 3: omitted = w, q = [a, b, c, d]
        float4 q;
        if (mode == 0) {
            q = float4(d, a, b, c);
        } else if (mode == 1) {
            q = float4(a, d, b, c);
        } else if (mode == 2) {
            q = float4(a, b, d, c);
        } else {
            q = float4(a, b, c, d);
        }

        return q;
    }

    // Decode color and opacity from sh0 texture using codebook
    inline float4 decodeColor(
        uint2 texCoord,
        texture2d<float, access::read> sh0Tex,
        constant float* codebook
    ) {
        float4 packed = sh0Tex.read(texCoord);

        // RGB indices into codebook
        float r = codebook[uint(packed.r * 255.0)];
        float g = codebook[uint(packed.g * 255.0)];
        float b = codebook[uint(packed.b * 255.0)];

        // Apply SH_C0 constant and convert to color
        float SH_C0 = 0.28209479177387814;
        float3 rgb = float3(r, g, b) * SH_C0 + 0.5;
        rgb = clamp(rgb, 0.0, 1.0);

        // Opacity: apply sigmoid inverse (stored as sigmoid(opacity))
        float alpha = packed.a;

        return float4(rgb, alpha);
    }

    // Build rotation-scale matrix from scale vector and quaternion
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
}

#endif // __METAL_VERSION__
