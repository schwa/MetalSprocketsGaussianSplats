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

// MARK: - Debug shader parameters

/// Parameters for distance-from-center debug visualization
struct DebugDistanceParams {
    simd_float3 center;     // Center point to measure distance from
    float maxDistance;      // Distance at which color is fully red
};

/// Parameters for splat-size debug visualization
struct DebugSizeParams {
    float minSize;          // Size at which color is fully blue
    float maxSize;          // Size at which color is fully red
};

/// Parameters for depth debug visualization
struct DebugDepthParams {
    float minDepth;         // Depth at which color is fully blue
    float maxDepth;         // Depth at which color is fully red
};

/// Parameters for aspect ratio debug visualization
struct DebugAspectRatioParams {
    float minRatio;         // Ratio at which color is fully blue (1.0 = circular)
    float maxRatio;         // Ratio at which color is fully red (elongated)
};

/// Maximum number of clouds that can have custom debug colors
#define MAX_DEBUG_CLOUD_COLORS 16

/// Parameters for cloud index debug visualization
struct DebugCloudIndexParams {
    unsigned int cloudCount;  // Total number of clouds
    simd_float3 cloudColors[MAX_DEBUG_CLOUD_COLORS];  // Custom colors for each cloud
};

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
