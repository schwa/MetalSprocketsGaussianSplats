#ifndef SOGDecodeShader_h
#define SOGDecodeShader_h

#import <simd/simd.h>

// Parameters for the GPU SOG decode kernel. All texture reads are raw integer
// texels (no sRGB / normalization), matching the byte values in the SOG planes.
struct SOGDecodeParams {
    unsigned int count;          // Number of splats

    simd_float3 meansMin;        // means mins (per axis)
    simd_float3 meansMax;        // means maxs (per axis)

    unsigned int shDegree;       // 0 = no higher-order SH, else 1..3
    unsigned int shNumCoeffs;    // coefficients per splat for shDegree (3, 8, or 15)
    unsigned int shFloatsPerSplat; // shNumCoeffs * 3
    unsigned int shCentroidsWidth; // width (in texels) of the centroids texture
    unsigned int shEntriesPerRow;  // palette entries per centroids row (64)
    unsigned int splatTexWidth;    // width (in texels) of the per-splat textures
};

#endif /* SOGDecodeShader_h */
