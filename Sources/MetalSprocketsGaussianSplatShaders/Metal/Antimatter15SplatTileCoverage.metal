#import "GaussianSplatShaders.h"
#import "Antimatter15SplatSupport.h"

#import <metal_logging>
#import <metal_stdlib>
#import <metal_uniform>

using namespace metal;
using namespace Antimatter15SplatSupport;

namespace Antimatter15SplatTileCoverage {

    // MARK: - Compute Shader

    [[kernel]] void compute_tile_overlaps(
        uint thread_id [[thread_position_in_grid]],
        constant GPUSplat *splats [[buffer(0)]],
        constant uint &splatCount [[buffer(1)]],
        constant float4x4 &modelMatrix [[buffer(2)]],
        constant float4x4 &viewMatrix [[buffer(3)]],
        constant float4x4 &projectionMatrix [[buffer(4)]],
        constant float2 &drawableSize [[buffer(5)]],
        constant float &scale [[buffer(6)]],
        constant uint2 &tileGridSize [[buffer(7)]],
        device atomic_uint *tileCounts [[buffer(8)]],
        device atomic_uint *maxCount [[buffer(9)]]
    ) {
        if (thread_id >= splatCount) {
            return;
        }

        const GPUSplat splat = splats[thread_id];

        // Compute projection (same as vertex shader)
        const float2 focal = float2(projectionMatrix[1][1], projectionMatrix[2][2]) * drawableSize / 2;
        const float4x4 modelViewMatrix = viewMatrix * modelMatrix;
        const float4 cam = modelViewMatrix * float4(splat.position, 1);
        float4 pos2d = projectionMatrix * cam;

        // Culling checks (same as vertex shader)
        const float clip = 1.2 * pos2d.w;
        if (pos2d.z < -clip || pos2d.x < -clip || pos2d.x > clip || pos2d.y < -clip || pos2d.y > clip) {
            return;
        }

        // Compute covariance and axes using shared function
        const CovarianceResult cov = computeCovariance(
            float2(splat.u1),
            float2(splat.u2),
            float2(splat.u3),
            cam,
            focal,
            modelViewMatrix
        );

        if (!cov.valid) {
            return;
        }

        // Compute bounding box
        BoundingBox bounds = computeSplatBoundingBox(pos2d, cov.majorAxis, cov.minorAxis, drawableSize, scale);

        // Clamp bounds to NDC space (-1 to 1)
        bounds.min = clamp(bounds.min, float2(-1.0), float2(1.0));
        bounds.max = clamp(bounds.max, float2(-1.0), float2(1.0));

        // Convert NDC to tile coordinates
        // NDC space: -1 to 1, grid space: 0 to tileGridSize
        // Convert from NDC [-1, 1] to grid coordinates [0, tileGridSize]
        const float2 minTileFloat = (bounds.min + 1.0) * 0.5 * float2(tileGridSize);
        const float2 maxTileFloat = (bounds.max + 1.0) * 0.5 * float2(tileGridSize);

        // Clamp to valid tile range
        const uint2 minTile = uint2(clamp(minTileFloat, float2(0.0), float2(tileGridSize - 1)));
        const uint2 maxTile = uint2(clamp(maxTileFloat, float2(0.0), float2(tileGridSize - 1)));

        // Increment count for all overlapping tiles
        for (uint y = minTile.y; y <= maxTile.y; y++) {
            for (uint x = minTile.x; x <= maxTile.x; x++) {
                uint tileIndex = y * tileGridSize.x + x;
                uint newCount = atomic_fetch_add_explicit(&tileCounts[tileIndex], 1u, memory_order_relaxed) + 1u;
                atomic_fetch_max_explicit(maxCount, newCount, memory_order_relaxed);
            }
        }
    }

    // MARK: - Tile Heat Map Rendering

    struct TileVertexOut {
        float4 position [[position]];
        float2 tileCoord;
    };

    [[vertex]] TileVertexOut tile_heatmap_vertex(
        uint vertex_id [[vertex_id]],
        constant float2 *vertices [[buffer(0)]],
        constant float2 &drawableSize [[buffer(1)]]
    ) {
        TileVertexOut out;
        out.position = float4(vertices[vertex_id], 0.0, 1.0);
        // Convert from NDC [-1, 1] to texture coordinates [0, 1]
        out.tileCoord = (vertices[vertex_id] + 1.0) * 0.5;
        return out;
    }

    [[fragment]] float4 tile_heatmap_fragment(
        TileVertexOut in [[stage_in]],
        constant uint2 &tileGridSize [[buffer(0)]],
        constant uint *tileCounts [[buffer(1)]],
        constant uint *maxCount [[buffer(2)]]
    ) {
        // Convert texture coordinates to tile indices
        uint2 tileIndex = uint2(in.tileCoord * float2(tileGridSize));
        tileIndex = clamp(tileIndex, uint2(0), tileGridSize - 1);

        uint index = tileIndex.y * tileGridSize.x + tileIndex.x;
        uint count = tileCounts[index];

        if (count == 0) {
            return float4(0.0, 0.0, 0.0, 0.0); // Transparent for empty tiles
        }

        // Normalize count to [0, 1]
        uint maxCountValue = maxCount[0];
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

}
