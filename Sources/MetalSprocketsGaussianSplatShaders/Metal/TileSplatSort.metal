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
    /// One thread per tile, uses device memory ping-pong between two buffers
    /// Uses tileOffsets for variable-length tile ranges
    /// After 4 passes (even number), result is back in buffer A
    [[kernel]] void tile_sort(
        uint tileIndex [[thread_position_in_grid]],
        device TileSplatIndex* tileSplatIndicesA [[buffer(0)]],
        device TileSplatIndex* tileSplatIndicesB [[buffer(1)]],
        device const uint* tileOffsets [[buffer(2)]],
        constant uint& numTiles [[buffer(3)]]
    ) {
        if (tileIndex >= numTiles) {
            return;
        }

        // Get tile's range from offsets
        uint startIndex = tileOffsets[tileIndex];
        uint endIndex = tileOffsets[tileIndex + 1];
        uint count = endIndex - startIndex;

        if (count <= 1) {
            return;
        }

        // Histogram for counting sort (256 buckets for 8-bit radix)
        uint histogram[256];

        // Ping-pong between device buffers
        device TileSplatIndex* src = tileSplatIndicesA + startIndex;
        device TileSplatIndex* dst = tileSplatIndicesB + startIndex;

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

            // Scatter to destination buffer
            for (uint i = 0; i < count; i++) {
                uint sortableKey = ~floatToSortableKey(src[i].depth);
                uint radixKey = getRadixKey(sortableKey, pass);
                uint destIndex = histogram[radixKey]++;
                dst[destIndex] = src[i];
            }

            // Swap src and dst for next pass
            device TileSplatIndex* tmp = src;
            src = dst;
            dst = tmp;
        }

        // After 4 passes (even number), result is in original src buffer (buffer A)
        // No copy needed - data is already in place
    }

} // namespace TileSplatSort
