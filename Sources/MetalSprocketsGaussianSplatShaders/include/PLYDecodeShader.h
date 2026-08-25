#ifndef PLYDecodeShader_h
#define PLYDecodeShader_h

#include <simd/simd.h>

struct PLYDecodeParams {
    uint64_t bodyOffset;
    uint32_t count;
    uint32_t recordStride;
    uint32_t shCoefficientCount;
    uint32_t semanticCount;
};

#endif
