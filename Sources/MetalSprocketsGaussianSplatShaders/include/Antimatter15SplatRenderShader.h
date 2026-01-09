#import <simd/simd.h>

// Metal debugger format: float3 position, uint32_t padding, half2 u1, half2 u2, half2 u3, uchar4 color

struct Antimatter15GPUSplat {
    simd_float3 position; // 12
    // padding // 4
    simd_half2 u1;     // 4
    simd_half2 u2;     // 4
    simd_half2 u3;     // 4
    simd_uchar4 color; // 4
};

// Metal debugger format: uint32_t splatIndex, uint16_t cloudIndex, half distanceToCamera
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

#ifdef __METAL_VERSION__
// For Metal shaders, provide a convenient typedef
typedef struct Antimatter15GPUSplat GPUSplat;
#endif
