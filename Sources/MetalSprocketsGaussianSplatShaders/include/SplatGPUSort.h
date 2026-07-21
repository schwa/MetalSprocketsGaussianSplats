#pragma once

#import <simd/simd.h>
#import "MetalSupport.h"

// Kernel parameter structs shared between the GPU splat sort `.metal` kernels
// and Swift. Plain C layout so a single definition is used by both sides.
//
// The GPU splat sort is an 8-bit LSD radix over the 16-bit `half` distance key
// carried on each `IndexedDistance`. Two passes (shift 0 and 8) suffice for a
// 16-bit key. The intermediate sort record is a `uint2`:
//   .x  low 16 bits  = order-preserving flipped half key (radix digit source)
//   .x  high 16 bits = cloudIndex (carried, untouched by digit extraction)
//   .y               = splatIndex (payload)

/// Parameters for the radix histogram / scan / scatter kernels.
struct SplatSortParams {
    unsigned int numElements;
    unsigned int numTiles;
    unsigned int elementsPerTile;
    unsigned int shift;         // 0 or 8
};

/// Parameters for the per-splat cull + distance kernel that builds the sort records.
struct SplatDistanceParams {
    float4x4 modelView;         // camera.inverse * model * cloudTransform (view 0)
    float4x4 projection;        // clip = projection * modelView * position (view 0)
    float4x4 modelView1;        // second view (stereo); valid when viewCount > 1
    float4x4 projection1;       // second projection (stereo); valid when viewCount > 1
    unsigned int viewCount;     // 1 = mono, 2 = stereo (cull keeps splats visible to either view)
    unsigned int numElements;   // total input splats (dispatch grid)
    unsigned int cloudIndex;    // carried into each record's high 16 bits
    unsigned int reversed;      // 1 = reverse sort order (flip distance sign)
    unsigned int cullEnabled;   // 1 = apply frustum cull, 0 = keep every splat
    float guardBand;            // fractional NDC margin kept beyond frustum edges
};
