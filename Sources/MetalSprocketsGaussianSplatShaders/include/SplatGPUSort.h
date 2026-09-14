#pragma once

#import <simd/simd.h>
#import "MetalSupport.h"

// Kernel parameter structs shared between the GPU splat sort `.metal` kernels
// and Swift. Plain C layout so a single definition is used by both sides.
//
// Intermediate records are uint2 (8 bytes): x holds the sortable depth key,
// y holds the splat index. In 16-bit mode x also carries cloudIndex in its high
// 16 bits; 32-bit mode uses all of x for depth and emits cloudIndex 0.
// Two or four 8-bit radix passes sort the selected key precision.

/// Parameters for the radix histogram / scan / scatter kernels.
struct SplatSortParams {
    unsigned int numElements;
    unsigned int numTiles;
    unsigned int elementsPerTile;
    unsigned int shift;         // 0, 8, 16, or 24
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
