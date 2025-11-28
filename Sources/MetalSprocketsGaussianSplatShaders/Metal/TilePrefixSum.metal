#import "GaussianSplatShaders.h"
#import "TileSplatSupport.h"

#import <metal_stdlib>

using namespace metal;

namespace TilePrefixSum {

    /// Compute exclusive prefix sum of tile counters
    /// Output: tileOffsets[i] = sum of tileCounters[0..i-1]
    /// tileOffsets[numTiles] = total count
    ///
    /// This is a simple single-threaded implementation suitable for ~10K tiles.
    /// For larger tile counts, a parallel prefix sum would be needed.
    [[kernel]] void tile_prefix_sum(
        device const uint* tileCounters [[buffer(0)]],
        device uint* tileOffsets [[buffer(1)]],
        constant uint& numTiles [[buffer(2)]]
    ) {
        uint sum = 0;
        for (uint i = 0; i < numTiles; i++) {
            tileOffsets[i] = sum;
            sum += tileCounters[i];
        }
        // Store total count at the end
        tileOffsets[numTiles] = sum;
    }

} // namespace TilePrefixSum
