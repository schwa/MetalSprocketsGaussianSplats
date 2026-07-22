#pragma once

// Shared types for the PointSplat renderer (RFC 0003).

#ifndef __METAL_VERSION__
#include <simd/simd.h>
#include <stdint.h>
typedef simd_float4x4 GPSFloat4x4;
typedef simd_float2 GPSDrawableSize;
typedef simd_float3 GPSFloat3;
typedef unsigned long long GPSPacked;
#else
typedef float4x4 GPSFloat4x4;
typedef float2 GPSDrawableSize;
typedef float3 GPSFloat3;
typedef ulong GPSPacked;
#endif

// 64-bit framebuffer packing (paper Sec. 3.1, after Schuetz et al. 2021):
// high 28 bits fixed-point view-space depth between near/far, low 36 bits
// 3x12-bit sRGB with range [0, 16) in 1/256 steps.
#define GPS_DEPTH_SHIFT 36
#define GPS_DEPTH_MAX ((GPSPacked)0x0FFFFFFF)
#define GPS_COLOR_MASK ((GPSPacked)0xFFFFFFFFF)

struct PointSplatUniforms {
    GPSFloat4x4 modelMatrix;
    GPSFloat4x4 viewMatrix;
    GPSFloat4x4 projectionMatrix;
    GPSDrawableSize drawableSize;   // supersampled framebuffer size in pixels
    float nearPlane;
    float farPlane;
    unsigned int splatCount;
    unsigned int frameSeed;
    unsigned int capacity;          // max threads per frame (T / K)
    unsigned int supersampling;     // linear supersampling factor S (1 or 2)
    unsigned int pointsPerThread;   // K; counts are in threads, each splats K points
    GPSFloat3 cameraPosition;       // world-space, for SH view direction
    unsigned int shDegree;          // 0 disables spherical harmonics
    // Occlusion culling (paper Sec. 3.5, two-phase):
    // 0 = off, 1 = phase 1 (cull vs previous depth pyramid),
    // 2 = phase 2 (only Gaussians culled in phase 1, vs fresh pyramid).
    unsigned int occlusionPhase;
    unsigned int pyramidLevels;     // mip levels in the depth pyramid
    unsigned int packedSplats;      // 1 = splat buffer holds GPSPackedSplat (issue #77)
    // Temporal point reuse (RFC 0005 §4): fraction of the point budget
    // covered by reprojected seed points from the previous frame; fresh
    // sampling is scaled by (1 - reuseFactor). 0 disables seeding.
    float reuseFactor;
};

// Quantized splat storage (issue #77, paper Sec. 4.1): 18 bytes per
// Gaussian versus SparkSplat's 32. Fixed-point means inside the cloud
// AABB, 10-bit log-space scales, smallest-three quaternion (2-bit max
// component index + 3 x 10-bit components), 8-bit color + opacity.
// All fields are 16-bit or smaller so the struct packs without padding.
struct GPSPackedSplat {
    unsigned short position[3];  // fixed-point in [positionMin, positionMin + positionExtent]
    unsigned short scale[2];     // low 30 bits: 3 x 10-bit log scales
    unsigned short rotation[2];  // 2-bit largest-component index + 3 x 10-bit smallest-three
    unsigned char color[4];      // rgb + opacity
};

// Dequantization ranges for a packed cloud; positions and log scales are
// stored normalized against these.
struct GPSPackedSplatBounds {
    GPSFloat3 positionMin;
    GPSFloat3 positionExtent;
    float logScaleMin;
    float logScaleExtent;
};

#ifndef __METAL_VERSION__
_Static_assert(sizeof(struct GPSPackedSplat) == 18, "GPSPackedSplat must be 18 bytes");
#endif

// Quantizes positive view-space depth to 28-bit fixed point between near/far.
static inline GPSPacked gps_pack_depth(float viewDepth, float nearPlane, float farPlane) {
    float normalized = (viewDepth - nearPlane) / (farPlane - nearPlane);
    normalized = normalized < 0.0f ? 0.0f : (normalized > 1.0f ? 1.0f : normalized);
    return (GPSPacked)(normalized * (float)GPS_DEPTH_MAX);
}

static inline float gps_unpack_depth(GPSPacked packed, float nearPlane, float farPlane) {
    float normalized = (float)(packed & GPS_DEPTH_MAX) / (float)GPS_DEPTH_MAX;
    return nearPlane + normalized * (farPlane - nearPlane);
}

// Packs a color channel in [0, 16) into 12 bits with 1/256 steps.
static inline GPSPacked gps_pack_channel(float value) {
    float scaled = value * 255.0f;
    scaled = scaled < 0.0f ? 0.0f : (scaled > 4095.0f ? 4095.0f : scaled);
    return (GPSPacked)(scaled + 0.5f);
}

static inline GPSPacked gps_pack_color(float r, float g, float b) {
    return (gps_pack_channel(r) << 24) | (gps_pack_channel(g) << 12) | gps_pack_channel(b);
}

static inline float gps_unpack_channel(GPSPacked packed, int shift) {
    return (float)((packed >> shift) & (GPSPacked)0xFFF) / 255.0f;
}
