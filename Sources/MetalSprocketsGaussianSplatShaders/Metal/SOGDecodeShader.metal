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

        // Scale: codebook lookup per channel, then exp. In v3, alpha holds rotation.
        uint4 s = scales.read(c);
        float3 scale = float3(
            exp(scalesCodebook[s.x]),
            exp(scalesCodebook[s.y]),
            exp(scalesCodebook[s.z])
        );

        float4 rot;
        if (params.version >= 3) {
            // v3: 24-bit exponential map in the alpha of means_l, means_u and scales.
            // p = (2/π)·θ·v/|v| with θ the half angle; each byte is (b - 128) / 127.
            float3 p = (float3(float(low.w), float(high.w), float(s.w)) - 128.0) / 127.0;
            float r = length(p);
            float theta = M_PI_2_F * r;
            float k = r > 0.0 ? sin(theta) / r : 0.0;
            rot = float4(p * k, cos(theta));
        } else {
            // v2: smallest-three in quats.webp.
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
            rot = float4(qx, qy, qz, qw);
        }
        rot = normalize(rot);

        // Color from SH0 codebook + DC term; alpha direct.
        uint4 col = sh0.read(c);
        float r = clamp(sh0Codebook[col.x] * SH_C0 + 0.5, 0.0, 1.0);
        float g = clamp(sh0Codebook[col.y] * SH_C0 + 0.5, 0.0, 1.0);
        float b = clamp(sh0Codebook[col.z] * SH_C0 + 0.5, 0.0, 1.0);
        // v2: alpha / 255. v3: (alpha / 204)², up to 1.5625. The renderer has no
        // opaque-core profile for opacity above 1, so clamp it, as the spec allows.
        float a = params.version >= 3 ? min(1.0, pow(float(col.w) / 204.0, 2.0)) : float(col.w) / 255.0;

        SparkSplat splat;
        splat.position = half3(position);
        splat.scale = half3(scale);
        // simd_half4 rotation stored as (x, y, z, w) matching simd_quatf(ix,iy,iz,r).
        splat.rotation = half4(rot);
        splat.color = uchar4(
            uchar(clamp(r, 0.0, 1.0) * 255.0),
            uchar(clamp(g, 0.0, 1.0) * 255.0),
            uchar(clamp(b, 0.0, 1.0) * 255.0),
            // Round: v3 alpha is not a multiple of 1/255, and truncation darkens it.
            uchar(rint(clamp(a, 0.0, 1.0) * 255.0))
        );
        // Indexed SH: store the palette row index; the palette is decoded once
        // by decodePalette instead of being expanded per splat.
        if (params.shDegree > 0) {
            uint4 lbl = shLabels.read(c);
            // v3 labels are 24-bit: the blue channel holds bits 16-23.
            splat.shIndex = lbl.x + (lbl.y << 8) + (params.version >= 3 ? (lbl.z << 16) : 0);
        } else {
            splat.shIndex = gid;
        }
        splatsOut[gid] = splat;
    }

    // Decodes the shared SH palette once: one thread per palette entry.
    [[kernel]] void decodePalette(
        uint gid [[thread_position_in_grid]],
        constant SOGDecodeParams &params [[buffer(0)]],
        device float *shOut [[buffer(2)]],
        constant float *shNCodebook [[buffer(5)]],
        texture2d<uint, access::read> shCentroids [[texture(5)]]
    ) {
        if (gid >= params.shPaletteCount || params.shDegree == 0) {
            return;
        }
        // Entries are shFileCoeffs texels wide; only the first shNumCoeffs are kept.
        uint paletteU = (gid % params.shEntriesPerRow) * params.shFileCoeffs;
        uint paletteV = gid / params.shEntriesPerRow;
        uint base = gid * params.shFloatsPerSplat;
        for (uint k = 0; k < params.shNumCoeffs; k++) {
            uint4 texel = shCentroids.read(uint2(paletteU + k, paletteV));
            shOut[base + k * 3 + 0] = shNCodebook[texel.x];
            shOut[base + k * 3 + 1] = shNCodebook[texel.y];
            shOut[base + k * 3 + 2] = shNCodebook[texel.z];
        }
    }

}; // namespace SOGDecodeShader
