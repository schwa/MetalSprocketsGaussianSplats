#import "GaussianSplatShaders.h"
#import "TileSplatSupport.h"

#import <metal_stdlib>

using namespace metal;
using namespace TileSplatSupport;

namespace TileSplatSort {

    // MARK: - Float to Sortable Key Conversion

    /// Convert float to sortable uint32 key
    /// Handles IEEE 754 float ordering: negative floats sort backwards in raw bits
    /// For negative: invert all bits (~bits)
    /// For positive: flip sign bit (bits ^ 0x80000000)
    inline uint floatToSortableKey(float f) {
        uint bits = as_type<uint>(f);
        uint signMask = 0x80000000u;
        return (bits & signMask) ? ~bits : bits ^ signMask;
    }

    /// Extract 8-bit key from sortable uint at given byte position (0-3, LSB first)
    inline uint getRadixKey(uint sortableKey, uint byteIndex) {
        return (sortableKey >> (byteIndex * 8)) & 0xFF;
    }

    // MARK: - Radix Sort Implementation

    /// Radix sort using 4 passes of 8-bit counting sort
    /// One thread per tile, sorts in-place using threadgroup memory
    [[kernel]] void tile_sort(
        uint tileIndex [[thread_position_in_grid]],
        device TileSplatIndex* tileSplatIndices [[buffer(0)]],
        device uint* tileCounters [[buffer(1)]],
        constant uint& numTiles [[buffer(2)]]
    ) {
        if (tileIndex >= numTiles) {
            return;
        }

        uint count = min(tileCounters[tileIndex], uint(MAX_SPLATS_PER_TILE));

        if (count <= 1) {
            return;
        }

        uint baseIndex = getTileBaseIndex(tileIndex);

        // Temporary storage for double-buffering during sort
        // Using stack arrays since we're single-threaded per tile
        TileSplatIndex temp[MAX_SPLATS_PER_TILE];
        uint histogram[256];

        // Pointers for double-buffering
        device TileSplatIndex* src = tileSplatIndices + baseIndex;
        thread TileSplatIndex* dst = temp;

        // 4 passes for 32-bit key (8 bits per pass, LSB first)
        for (uint pass = 0; pass < 4; pass++) {
            // Clear histogram
            for (uint i = 0; i < 256; i++) {
                histogram[i] = 0;
            }

            // Build histogram
            for (uint i = 0; i < count; i++) {
                // Convert depth to sortable key and invert for descending order (front-to-back)
                uint sortableKey = ~floatToSortableKey(src[i].depth);
                uint radixKey = getRadixKey(sortableKey, pass);
                histogram[radixKey]++;
            }

            // Exclusive prefix sum
            uint sum = 0;
            for (uint i = 0; i < 256; i++) {
                uint val = histogram[i];
                histogram[i] = sum;
                sum += val;
            }

            // Scatter to destination
            for (uint i = 0; i < count; i++) {
                uint sortableKey = ~floatToSortableKey(src[i].depth);
                uint radixKey = getRadixKey(sortableKey, pass);
                uint destIndex = histogram[radixKey]++;
                dst[destIndex] = src[i];
            }

            // Swap buffers for next pass
            if (pass < 3) {
                // Copy back to device buffer for next pass
                for (uint i = 0; i < count; i++) {
                    src[i] = dst[i];
                }
            }
        }

        // Final copy back to device buffer (result is in temp after 4 passes)
        for (uint i = 0; i < count; i++) {
            (tileSplatIndices + baseIndex)[i] = temp[i];
        }
    }

} // namespace TileSplatSort
