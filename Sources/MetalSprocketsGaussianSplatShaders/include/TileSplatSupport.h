#ifndef TileSplatSupport_h
#define TileSplatSupport_h

#import <simd/simd.h>

// MARK: - Tile Configuration Constants

#define TILE_SIZE 16
#define MAX_SPLATS_PER_TILE 2048
#define ALPHA_THRESHOLD 0.95f

// Function constant indices for shader specialization
#define FC_DEBUG_TILE_OVERFLOW 0
#define FC_DEBUG_TILE_BORDERS 1

// MARK: - Data Structures

/// Index and depth for a splat in a tile's list (8 bytes)
struct TileSplatIndex {
    uint32_t splatID;    // Index into SparkSplat buffer
    float depth;         // Camera-space Z for sorting (negative = in front of camera)
};

/// Uniforms for tile-based rendering
struct TileRenderUniforms {
    simd_float4x4 modelMatrix;
    simd_float4x4 viewMatrix;
    simd_float4x4 projectionMatrix;
    simd_float2 drawableSize;
    simd_uint2 tileGridSize;
    uint32_t maxSplatsPerTile;
    float scale;
};

#ifdef __METAL_VERSION__

#import <metal_stdlib>
#import <metal_imageblocks>

namespace TileSplatSupport {
    using namespace metal;

    // MARK: - Imageblock Structure for Tile Memory

    /// Imageblock structure for tile-local memory
    /// Stores accumulated color during tile rendering
    struct TileSplatImageblock {
        half4 color [[raster_order_group(0)]];
    };

    // MARK: - Constants

    constant float MAX_STD_DEV = 2.8284271247;  // sqrt(8)
    constant float MIN_ALPHA = 0.5 / 255.0;
    constant float CLIP_XY = 1.4;
    constant float MAX_PIXEL_RADIUS = 512.0;

    // MARK: - Tile Coordinate Helpers

    /// Convert pixel coordinate to tile index
    inline uint2 pixelToTile(uint2 pixelCoord) {
        return pixelCoord / TILE_SIZE;
    }

    /// Convert tile coordinate to linear tile index
    inline uint tileToLinearIndex(uint2 tileCoord, uint2 tileGridSize) {
        return tileCoord.y * tileGridSize.x + tileCoord.x;
    }

    /// Get the base index into tileSplatIndices buffer for a tile
    inline uint getTileBaseIndex(uint tileIndex) {
        return tileIndex * MAX_SPLATS_PER_TILE;
    }

    // MARK: - Bounding Box in Tile Space

    /// Convert NDC bounding box to tile coordinates
    inline void ndcBoundsToTiles(
        float2 ndcMin,
        float2 ndcMax,
        uint2 tileGridSize,
        thread uint2& minTile,
        thread uint2& maxTile
    ) {
        // NDC space: -1 to 1, grid space: 0 to tileGridSize
        float2 minTileFloat = (ndcMin + 1.0) * 0.5 * float2(tileGridSize);
        float2 maxTileFloat = (ndcMax + 1.0) * 0.5 * float2(tileGridSize);

        // Clamp to valid tile range
        minTile = uint2(clamp(minTileFloat, float2(0.0), float2(tileGridSize - 1)));
        maxTile = uint2(clamp(maxTileFloat, float2(0.0), float2(tileGridSize - 1)));
    }

    // MARK: - Front-to-Back Blending

    /// Accumulate color using front-to-back alpha blending
    /// Returns true if opacity threshold reached (can early exit)
    inline bool accumulateFrontToBack(
        float4 splatColor,
        float splatAlpha,
        thread float4& accumulatedColor,
        thread float& accumulatedAlpha
    ) {
        float weight = splatAlpha * (1.0 - accumulatedAlpha);
        accumulatedColor.rgb += splatColor.rgb * weight;
        accumulatedAlpha += weight;

        return accumulatedAlpha >= ALPHA_THRESHOLD;
    }

}

#endif // __METAL_VERSION__

#endif // TileSplatSupport_h
