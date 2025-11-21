#ifndef GenericSplat_h
#define GenericSplat_h

#import <simd/simd.h>

// GPU-side GenericSplat struct matching Swift layout
struct GenericSplat {
    simd_float3 position;
    simd_float3 scale;
    simd_float4 color;
    simd_float4 rotation;
};

#endif /* GenericSplat_h */
