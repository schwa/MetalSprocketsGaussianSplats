#ifndef SparkSplatRenderShader_h
#define SparkSplatRenderShader_h

#import <simd/simd.h>

/// SparkSplat - 24-byte simplified format using half-floats
struct SparkSplat {
    simd_half3 position;   // 6 bytes
    simd_half3 scale;      // 6 bytes
    simd_half4 rotation;          // 8 bytes
    simd_uchar4 color;            // 4 bytes
};

_Static_assert(sizeof(struct SparkSplat) == 32, "SparkSplat must be 32 bytes");

#endif /* SparkSplatRenderShader_h */
