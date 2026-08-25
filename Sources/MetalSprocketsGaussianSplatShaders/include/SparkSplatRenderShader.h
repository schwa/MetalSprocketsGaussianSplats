#ifndef SparkSplatRenderShader_h
#define SparkSplatRenderShader_h

#import <simd/simd.h>
#import "MetalSupport.h"

// MARK: - Bounding Box structure

/// Axis-aligned bounding box for splat culling (world space)
struct BoundingBox3D {
    simd_float3 minBounds;
    simd_float3 maxBounds;
};

// MARK: - IndexedDistance structure

/// Sorted index with distance for depth-ordered rendering
#ifdef __METAL_VERSION__
struct IndexedDistance {
    unsigned int splatIndex;
    unsigned short cloudIndex;
    half distanceToCamera;
};
#else
struct IndexedDistance {
    unsigned int splatIndex;
    unsigned short cloudIndex;
    simd_half1 distanceToCamera;
};
#endif

// MARK: - SparkSplat structure

/// SparkSplat - 32-byte format using half-floats
struct SparkSplat {
    simd_half3 position;   // 6 bytes
    simd_half3 scale;      // 6 bytes
    simd_half4 rotation;   // 8 bytes
    simd_uchar4 color;     // 4 bytes
    // 8 bytes padding to reach 32
};

_Static_assert(sizeof(struct SparkSplat) == 32, "SparkSplat must be 32 bytes");

// MARK: - Multi-cloud argument buffer structures

/// Per-cloud data for multi-cloud rendering
struct SplatCloudData {
    BUFFER(device, struct SparkSplat *) splats;
    float4x4 modelMatrix;
    BUFFER(device, float *) shCoefficients;  // Can be null if no SH for this cloud
    float opacity;  // Cloud-level opacity multiplier (0.0 - 1.0)
};

/// Argument buffer containing array of cloud data
struct MultiCloudArgumentBuffer {
    unsigned int cloudCount;
    BUFFER(device, struct SplatCloudData *) clouds;
};

#endif /* SparkSplatRenderShader_h */
