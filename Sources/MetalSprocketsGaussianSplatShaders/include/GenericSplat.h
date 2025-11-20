#ifndef GenericSplat_h
#define GenericSplat_h

#import <simd/simd.h>

// GPU-side GenericSplat struct matching Swift layout
// Note: SIMD3<Float> in Swift is 16 bytes (padded), simd_quatf is float4
struct GenericSplat {
    simd_float3 position;   // 12 bytes + 4 padding = 16 bytes
    simd_float3 scale;      // 12 bytes + 4 padding = 16 bytes
    simd_float4 color;      // 16 bytes (RGBA)
    simd_float4 rotation;   // 16 bytes (quaternion as xyzw)
};  // Total: 64 bytes

#endif /* GenericSplat_h */
