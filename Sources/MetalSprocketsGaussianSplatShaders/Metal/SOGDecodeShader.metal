#import "GaussianSplatShaders.h"

#import <metal_stdlib>

using namespace metal;

// GPU implementation of the SOG de-quantize loop (driven by SOGReaderGPU).
// One thread per splat. Reads raw integer texels from the SOG textures and
// writes a SparkSplat (and, if present, flattened higher-order SH floats).
namespace SOGDecodeShader {

    constant float SH_C0 = 0.28209479177387814;
    constant float SQRT2 = 1.4142135623730951;

    inline float invLog(float v) {
        float a = abs(v);
        float e = exp(a) - 1.0;
        return v < 0.0 ? -e : e;
    }

    // Convert a linear splat index to integer texel coords for the per-splat textures.
    inline uint2 splatCoord(uint index, uint width) {
        return uint2(index % width, index / width);
    }

    [[kernel]] void decode(
        uint gid [[thread_position_in_grid]],
        constant SOGDecodeParams &params [[buffer(0)]],
        device SparkSplat *splatsOut [[buffer(1)]],
        device float *shOut [[buffer(2)]],           // may be unused if shDegree == 0
        constant float *scalesCodebook [[buffer(3)]],
        constant float *sh0Codebook [[buffer(4)]],
        constant float *shNCodebook [[buffer(5)]],   // may be unused if shDegree == 0
        texture2d<uint, access::read> meansLow [[texture(0)]],
        texture2d<uint, access::read> meansHigh [[texture(1)]],
        texture2d<uint, access::read> scales [[texture(2)]],
        texture2d<uint, access::read> quats [[texture(3)]],
        texture2d<uint, access::read> sh0 [[texture(4)]],
        texture2d<uint, access::read> shCentroids [[texture(5)]],
        texture2d<uint, access::read> shLabels [[texture(6)]]
    ) {
        if (gid >= params.count) {
            return;
        }

        uint2 c = splatCoord(gid, params.splatTexWidth);

        uint4 low = meansLow.read(c);
        uint4 high = meansHigh.read(c);

        // Position: recombine 16-bit, normalize, lerp mins->maxs, invLog.
        uint rawX = (high.x << 8) | low.x;
        uint rawY = (high.y << 8) | low.y;
        uint rawZ = (high.z << 8) | low.z;
        float tx = float(rawX) / 65535.0;
        float ty = float(rawY) / 65535.0;
        float tz = float(rawZ) / 65535.0;
        float logX = params.meansMin.x + tx * (params.meansMax.x - params.meansMin.x);
        float logY = params.meansMin.y + ty * (params.meansMax.y - params.meansMin.y);
        float logZ = params.meansMin.z + tz * (params.meansMax.z - params.meansMin.z);
        float3 position = float3(invLog(logX), invLog(logY), invLog(logZ));

        // Scale: codebook lookup per channel, then exp.
        uint4 s = scales.read(c);
        float3 scale = float3(
            exp(scalesCodebook[s.x]),
            exp(scalesCodebook[s.y]),
            exp(scalesCodebook[s.z])
        );

        // Rotation: smallest-3 encoding.
        uint4 q = quats.read(c);
        float r0 = (float(q.x) / 255.0 - 0.5) * SQRT2;
        float r1 = (float(q.y) / 255.0 - 0.5) * SQRT2;
        float r2 = (float(q.z) / 255.0 - 0.5) * SQRT2;
        float rr = sqrt(max(0.0, 1.0 - r0 * r0 - r1 * r1 - r2 * r2));
        int rOrder = int(q.w) - 252;

        float qx = rOrder == 0 ? r0 : (rOrder == 1 ? rr : r1);
        float qy = rOrder <= 1 ? r1 : (rOrder == 2 ? rr : r2);
        float qz = rOrder <= 2 ? r2 : rr;
        float qw = rOrder == 0 ? rr : r0;
        float4 rot = float4(qx, qy, qz, qw);
        rot = normalize(rot);

        // Color from SH0 codebook + DC term; alpha direct.
        uint4 col = sh0.read(c);
        float r = clamp(sh0Codebook[col.x] * SH_C0 + 0.5, 0.0, 1.0);
        float g = clamp(sh0Codebook[col.y] * SH_C0 + 0.5, 0.0, 1.0);
        float b = clamp(sh0Codebook[col.z] * SH_C0 + 0.5, 0.0, 1.0);
        float a = float(col.w) / 255.0;

        SparkSplat splat;
        splat.position = half3(position);
        splat.scale = half3(scale);
        // simd_half4 rotation stored as (x, y, z, w) matching simd_quatf(ix,iy,iz,r).
        splat.rotation = half4(rot);
        splat.color = uchar4(
            uchar(clamp(r, 0.0, 1.0) * 255.0),
            uchar(clamp(g, 0.0, 1.0) * 255.0),
            uchar(clamp(b, 0.0, 1.0) * 255.0),
            uchar(clamp(a, 0.0, 1.0) * 255.0)
        );
        splatsOut[gid] = splat;

        // Higher-order SH.
        if (params.shDegree > 0) {
            uint4 lbl = shLabels.read(c);
            uint paletteIndex = lbl.x + (lbl.y << 8);
            uint paletteU = (paletteIndex % params.shEntriesPerRow) * params.shNumCoeffs;
            uint paletteV = paletteIndex / params.shEntriesPerRow;

            uint base = gid * params.shFloatsPerSplat;
            for (uint k = 0; k < params.shNumCoeffs; k++) {
                uint2 pc = uint2(paletteU + k, paletteV);
                uint4 texel = shCentroids.read(pc);
                shOut[base + k * 3 + 0] = shNCodebook[texel.x];
                shOut[base + k * 3 + 1] = shNCodebook[texel.y];
                shOut[base + k * 3 + 2] = shNCodebook[texel.z];
            }
        }
    }

}; // namespace SOGDecodeShader
