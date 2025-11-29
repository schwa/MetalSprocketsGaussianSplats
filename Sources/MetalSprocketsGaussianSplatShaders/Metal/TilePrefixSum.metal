#import "GaussianSplatShaders.h"
#import "TileSplatSupport.h"

#import <metal_stdlib>

using namespace metal;

namespace TilePrefixSum {

    /// Compute exclusive prefix sum of tile counters and find max tile count
    /// Output: tileOffsets[i] = sum of tileCounters[0..i-1]
    /// tileOffsets[numTiles] = total count
    /// maxTileCount[0] = maximum count across all tiles (for heatmap normalization)
    ///
    /// This is a simple single-threaded implementation suitable for ~10K tiles.
    /// For larger tile counts, a parallel prefix sum would be needed.
    [[kernel]] void tile_prefix_sum(
        device const uint* tileCounters [[buffer(0)]],
        device uint* tileOffsets [[buffer(1)]],
        constant uint& numTiles [[buffer(2)]],
        device uint* maxTileCount [[buffer(3)]]
    ) {
        uint sum = 0;
        uint maxCount = 0;
        for (uint i = 0; i < numTiles; i++) {
            tileOffsets[i] = sum;
            uint count = tileCounters[i];
            sum += count;
            maxCount = max(maxCount, count);
        }
        // Store total count at the end
        tileOffsets[numTiles] = sum;
        // Store max count for heatmap normalization
        maxTileCount[0] = maxCount;
    }

    // MARK: - Tile Heatmap Rendering

    // Function constant for tile border rendering
    constant bool showTileBorders [[function_constant(0)]];

    struct TileHeatmapVertexOut {
        float4 position [[position]];
        float2 tileCoord;
    };

    [[vertex]] TileHeatmapVertexOut tile_heatmap_vertex(
        uint vertex_id [[vertex_id]],
        constant float2* vertices [[buffer(0)]]
    ) {
        TileHeatmapVertexOut out;
        out.position = float4(vertices[vertex_id], 0.0, 1.0);
        // Convert from NDC [-1, 1] to texture coordinates [0, 1]
        out.tileCoord = (vertices[vertex_id] + 1.0) * 0.5;
        return out;
    }

    [[fragment]] float4 tile_heatmap_fragment(
        TileHeatmapVertexOut in [[stage_in]],
        constant uint2& tileGridSize [[buffer(0)]],
        constant uint* tileCounters [[buffer(1)]],
        constant uint* maxTileCount [[buffer(2)]],
        constant float2& drawableSize [[buffer(3)]]
    ) {
        // Draw red border at tile edges (if enabled)
        if (showTileBorders) {
            float2 pixelPos = in.position.xy;
            uint tileSize = TILE_SIZE;
            uint2 pixelInTile = uint2(pixelPos) % tileSize;
            if (pixelInTile.x == 0 || pixelInTile.y == 0) {
                return float4(1.0, 0.0, 0.0, 0.8);
            }
        }

        // Convert texture coordinates to tile indices (flip Y to match screen space)
        float2 flippedCoord = float2(in.tileCoord.x, 1.0 - in.tileCoord.y);
        uint2 tileIndex = uint2(flippedCoord * float2(tileGridSize));
        tileIndex = clamp(tileIndex, uint2(0), tileGridSize - 1);

        uint index = tileIndex.y * tileGridSize.x + tileIndex.x;
        uint count = tileCounters[index];

        if (count == 0) {
            return float4(0.0, 0.0, 0.0, 0.0); // Transparent for empty tiles
        }

        // Normalize count to [0, 1]
        uint maxCountValue = maxTileCount[0];
        if (maxCountValue == 0) {
            maxCountValue = 1;
        }
        float normalized = float(count) / float(maxCountValue);

        // Heat map color gradient: blue -> green -> yellow -> red
        float3 color;
        if (normalized < 0.33) {
            // Blue to Green
            float t = normalized / 0.33;
            color = mix(float3(0.0, 0.0, 1.0), float3(0.0, 1.0, 0.0), t);
        } else if (normalized < 0.66) {
            // Green to Yellow
            float t = (normalized - 0.33) / 0.33;
            color = mix(float3(0.0, 1.0, 0.0), float3(1.0, 1.0, 0.0), t);
        } else {
            // Yellow to Red
            float t = (normalized - 0.66) / 0.34;
            color = mix(float3(1.0, 1.0, 0.0), float3(1.0, 0.0, 0.0), t);
        }

        return float4(color, 0.5); // Semi-transparent
    }

} // namespace TilePrefixSum
