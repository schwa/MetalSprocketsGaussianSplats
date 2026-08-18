#import "GaussianSplatShaders.h"

#import <metal_stdlib>

using namespace metal;

// GPU implementation of the SPZ per-splat unpack loop (driven by SPZReaderGPU).
// One thread per splat: reads the packed bytes from the decompressed SPZ payload
// and writes a SparkSplat (and, if present, flattened SH floats). The math
// mirrors SPZReader's CPU unpack functions exactly.
namespace SPZUnpackShader {

    constant float SH_C0 = 0.28209479177387814;
    constant float SQRT1_2 = 0.707106781186547524401;

    // Signed 24-bit little-endian integer at a byte offset.
    inline int readFixed24(device const uchar *payload, uint offset) {
        uint v = uint(payload[offset]) | (uint(payload[offset + 1]) << 8) | (uint(payload[offset + 2]) << 16);
        if (v & 0x800000u) {
            v |= 0xff000000u;
        }
        return int(v);
    }

    [[kernel]] void unpack(
        uint gid [[thread_position_in_grid]],
        constant SPZDecodeParams &p [[buffer(0)]],
        device const uchar *payload [[buffer(1)]],
        device SparkSplat *splatsOut [[buffer(2)]],
        device float *shOut [[buffer(3)]]   // may be unused if shCoeffCount == 0
    ) {
        if (gid >= p.count) {
            return;
        }

        // Position: three 24-bit fixed-point values / 2^fractionalBits.
        float scaleDiv = float(1u << p.fractionalBits);
        uint posBase = p.positionsOffset + gid * 9;
        float3 position = float3(
            float(readFixed24(payload, posBase + 0)) / scaleDiv,
            float(readFixed24(payload, posBase + 3)) / scaleDiv,
            float(readFixed24(payload, posBase + 6)) / scaleDiv
        );

        // Scale: byte/16 - 10 (log space), then exp.
        uint scaleBase = p.scalesOffset + gid * 3;
        float3 scale = float3(
            exp(float(payload[scaleBase + 0]) / 16.0 - 10.0),
            exp(float(payload[scaleBase + 1]) / 16.0 - 10.0),
            exp(float(payload[scaleBase + 2]) / 16.0 - 10.0)
        );

        // Color: SH DC coefficient -> RGB; alpha via sigmoid(invSigmoid(byte/255)).
        uint colorBase = p.colorsOffset + gid * 3;
        float3 rgb;
        for (uint i = 0; i < 3; i++) {
            float c = ((float(payload[colorBase + i]) / 255.0) - 0.5) / 0.15;
            rgb[i] = clamp(c * SH_C0 + 0.5, 0.0, 1.0);
        }
        float ap = float(payload[p.alphasOffset + gid]) / 255.0;
        float logit = (ap > 0.0 && ap < 1.0) ? log(ap / (1.0 - ap)) : ap;
        float alpha = clamp(1.0 / (1.0 + exp(-logit)), 0.0, 1.0);

        // Rotation.
        uint rotBase = p.rotationsOffset + gid * p.rotationBytes;
        float4 quat;
        if (p.rotationBytes == 4) {
            // Smallest-three: 2-bit largest index + three 9-bit magnitudes + sign.
            uint comp = uint(payload[rotBase]) | (uint(payload[rotBase + 1]) << 8)
                | (uint(payload[rotBase + 2]) << 16) | (uint(payload[rotBase + 3]) << 24);
            uint iLargest = comp >> 30;
            uint cMask = (1u << 9) - 1;
            float rotation[4] = {0, 0, 0, 0};
            float sumSquares = 0;
            uint tempComp = comp;
            // Extract three components in descending index order, skipping iLargest.
            for (int i = 3; i >= 0; i--) {
                if (uint(i) == iLargest) {
                    continue;
                }
                uint mag = tempComp & cMask;
                uint negbit = (tempComp >> 9) & 0x1;
                tempComp = tempComp >> 10;
                float value = SQRT1_2 * float(mag) / float(cMask);
                if (negbit == 1) {
                    value = -value;
                }
                rotation[i] = value;
                sumSquares += value * value;
            }
            rotation[iLargest] = sqrt(max(0.0, 1.0 - sumSquares));
            quat = float4(rotation[0], rotation[1], rotation[2], rotation[3]);
        } else {
            // SPZ v2: three signed components, w reconstructed.
            float x = float(payload[rotBase + 0]) / 127.5 - 1.0;
            float y = float(payload[rotBase + 1]) / 127.5 - 1.0;
            float z = float(payload[rotBase + 2]) / 127.5 - 1.0;
            float w = sqrt(max(0.0, 1.0 - (x * x + y * y + z * z)));
            quat = float4(x, y, z, w);
        }

        SparkSplat splat;
        splat.position = half3(position);
        splat.scale = half3(scale);
        splat.rotation = half4(quat);   // (x, y, z, w), matching simd_quatf.vector
        splat.color = uchar4(
            uchar(rgb.x * 255.0),
            uchar(rgb.y * 255.0),
            uchar(rgb.z * 255.0),
            uchar(alpha * 255.0)
        );
        splatsOut[gid] = splat;

        // Spherical harmonics: (byte - 128) / 128 per coefficient-channel.
        if (p.shCoeffCount > 0) {
            uint n = p.shCoeffCount * 3;
            uint shBase = p.shOffset + gid * n;
            uint outBase = gid * n;
            for (uint k = 0; k < n; k++) {
                shOut[outBase + k] = (float(payload[shBase + k]) - 128.0) / 128.0;
            }
        }
    }

}; // namespace SPZUnpackShader
