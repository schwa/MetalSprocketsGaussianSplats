#pragma once

// Shared types for the PointSplat renderer (RFC 0003).

#ifndef __METAL_VERSION__
#include <simd/simd.h>
#include <stdint.h>
typedef simd_float4x4 GPSFloat4x4;
typedef simd_float2 GPSDrawableSize;
typedef unsigned long long GPSPacked;
#else
typedef float4x4 GPSFloat4x4;
typedef float2 GPSDrawableSize;
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
    unsigned int capacity;          // max points per frame (T)
};

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
