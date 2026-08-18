#ifndef SPZUnpackShader_h
#define SPZUnpackShader_h

#import <simd/simd.h>

// Parameters for the GPU SPZ unpack kernel. All offsets are byte offsets into
// the decompressed SPZ payload buffer; the layout mirrors SPZReader's sections
// (positions, alphas, colors, scales, rotations, spherical harmonics).
struct SPZDecodeParams {
    unsigned int count;           // Number of splats
    unsigned int shCoeffCount;    // SH coefficients per channel (0, 3, 8, 15, 24)
    unsigned int fractionalBits;  // Fixed-point fractional bits for positions
    unsigned int rotationBytes;   // 3 (SPZ v2) or 4 (SPZ v3+, smallest-three)
    unsigned int positionsOffset;
    unsigned int alphasOffset;
    unsigned int colorsOffset;
    unsigned int scalesOffset;
    unsigned int rotationsOffset;
    unsigned int shOffset;
};

#endif /* SPZUnpackShader_h */
