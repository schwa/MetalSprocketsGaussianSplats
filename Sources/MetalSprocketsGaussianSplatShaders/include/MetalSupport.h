// MetalSupport.h — Cross-environment macros for Metal/Swift interop headers
#pragma once

#import <simd/simd.h>

#if defined(__METAL_VERSION__)
#import <metal_stdlib>
#define BUFFER(ADDRESS_SPACE, TYPE) ADDRESS_SPACE TYPE
#else
#import <Metal/Metal.h>
#define BUFFER(ADDRESS_SPACE, TYPE) TYPE
#endif

typedef simd_float4x4 float4x4;
