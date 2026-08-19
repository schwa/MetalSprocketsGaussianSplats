#import "GaussianSplatShaders.h"
#import "SparkSplatRenderShader.h"
#import "SparkSplatSupport.h"
#import "TileSplatSupport.h"

#import <metal_stdlib>

using namespace metal;
using namespace SparkSplatSupport;
using namespace TileSplatSupport;

namespace TileSplatBinning {

    // MARK: - Shared Splat Processing

    /// Computes the tile bounds for a splat. Returns false if the splat is culled.
    inline bool computeSplatTileBounds(
        uint splatID,
        constant SparkSplat* splats,
        constant float4x4& modelMatrix,
        constant float4x4& viewMatrix,
        constant float4x4& projectionMatrix,
        constant float2& drawableSize,
        constant uint2& tileGridSize,
        thread uint2& minTile,
        thread uint2& maxTile,
        thread float& depth,
        thread TileProjectedSplat& projected
    ) {
        SparkSplat splat = splats[splatID];

        float3 center = float3(splat.position);
        float3 scales = float3(splat.scale);
        float4 quaternion = float4(splat.rotation);
        float4 rgba = float4(splat.color) / 255.0;

        if (rgba.a < MIN_ALPHA) {
            return false;
        }

        if (scales.x == 0.0 && scales.y == 0.0 && scales.z == 0.0) {
            return false;
        }

        float4 worldCenter = modelMatrix * float4(center, 1.0);

        float4 viewCenter4 = viewMatrix * worldCenter;
        float3 viewCenter = viewCenter4.xyz;

        // Cull splats behind the camera.
        if (viewCenter.z >= 0.0) {
            return false;
        }

        // Depth for sorting: negative Z, so closer is a larger value.
        depth = viewCenter.z;

        float4 clipCenter = projectionMatrix * float4(viewCenter, 1.0);

        // Cull outside the near and far planes.
        if (abs(clipCenter.z) >= clipCenter.w) {
            return false;
        }

        // Cull outside the XY frustum.
        float clip = CLIP_XY * clipCenter.w;
        if (abs(clipCenter.x) > clip || abs(clipCenter.y) > clip) {
            return false;
        }

        float3x3 localRS = scaleQuaternionToMatrix(scales, quaternion);
        float3x3 viewRS = transformToViewSpace(modelMatrix, viewMatrix, localRS);

        float3x3 cov3D = compute3DCovariance(viewRS);

        float2 focal = computeFocalLength(projectionMatrix, drawableSize);
        float3x3 J = computeProjectionJacobian(viewCenter, focal);
        Covariance2D cov2D = projectCovarianceTo2D(cov3D, J);

        // Small blur for anti-aliasing.
        float blurAmount = 0.3;
        float detOrig = cov2D.a * cov2D.d - cov2D.b * cov2D.b;
        cov2D.a += blurAmount;
        cov2D.d += blurAmount;
        float det = cov2D.a * cov2D.d - cov2D.b * cov2D.b;

        if (det <= 0.0) {
            return false;
        }

        Eigen2D eigen = eigendecompose2D(cov2D, MAX_PIXEL_RADIUS, MAX_STD_DEV);

        float3 ndcCenter = clipCenter.xyz / clipCenter.w;

        // Precompute the per-pixel evaluation data: screen-space center,
        // inverse covariance (conic), and anti-aliased base alpha. The
        // render loop evaluates only this, never the projection math.
        float2 screenCenter = float2(
            (ndcCenter.x + 1.0) * 0.5 * drawableSize.x,
            (1.0 - ndcCenter.y) * 0.5 * drawableSize.y
        );
        float invDet = 1.0 / det;
        // Screen Y is flipped from NDC, which negates the off-diagonal term.
        float3 conic = float3(cov2D.d * invDet, cov2D.b * invDet, cov2D.a * invDet);
        float blurAdjust = sqrt(max(0.0, detOrig / det));
        float baseAlpha = rgba.a * blurAdjust;
        projected.centerConicAB = float4(screenCenter, conic.x, conic.y);
        projected.colorAlpha = float4(pow(rgba.rgb, float3(2.2)), baseAlpha);
        projected.conicD = conic.z;

        float2 majorAxisNDC = (2.0 / drawableSize) * eigen.majorAxis;
        float2 minorAxisNDC = (2.0 / drawableSize) * eigen.minorAxis;

        float2 extent = abs(majorAxisNDC) + abs(minorAxisNDC);

        // Minimum padding of 1 tile in NDC handles small and distant splats.
        // Splats near the tile boundaries then reach the neighboring tiles.
        float2 tilePaddingNDC = 2.0 * float2(TILE_SIZE) / drawableSize;
        extent = max(extent, tilePaddingNDC);

        float2 ndcMin = ndcCenter.xy - extent;
        float2 ndcMax = ndcCenter.xy + extent;

        ndcMin = clamp(ndcMin, float2(-1.0), float2(1.0));
        ndcMax = clamp(ndcMax, float2(-1.0), float2(1.0));

        ndcBoundsToTiles(ndcMin, ndcMax, tileGridSize, minTile, maxTile);

        return true;
    }

    // MARK: - Phase 1: Count Splats Per Tile

    /// Counts how many splats overlap each tile (phase 1 of binning). One thread per splat.
    [[kernel]] void tile_binning_count(
        uint splatID [[thread_position_in_grid]],
        constant SparkSplat* splats [[buffer(0)]],
        constant uint& splatCount [[buffer(1)]],
        constant float4x4& modelMatrix [[buffer(2)]],
        constant float4x4& viewMatrix [[buffer(3)]],
        constant float4x4& projectionMatrix [[buffer(4)]],
        constant float2& drawableSize [[buffer(5)]],
        constant float& scale [[buffer(6)]],
        constant uint2& tileGridSize [[buffer(7)]],
        device atomic_uint* tileCounters [[buffer(8)]]
    ) {
        if (splatID >= splatCount) {
            return;
        }

        uint2 minTile, maxTile;
        float depth;
        TileProjectedSplat projected;

        if (!computeSplatTileBounds(splatID, splats, modelMatrix, viewMatrix,
                                     projectionMatrix, drawableSize, tileGridSize,
                                     minTile, maxTile, depth, projected)) {
            return;
        }

        for (uint ty = minTile.y; ty <= maxTile.y; ty++) {
            for (uint tx = minTile.x; tx <= maxTile.x; tx++) {
                uint tileIndex = tileToLinearIndex(uint2(tx, ty), tileGridSize);
                atomic_fetch_add_explicit(&tileCounters[tileIndex], 1u, memory_order_relaxed);
            }
        }
    }

    // MARK: - Phase 2: Write Splats to Compacted Buffer

    /// Writes splats to the compacted buffer with precomputed offsets (phase 2). One thread per splat.
    [[kernel]] void tile_binning_write(
        uint splatID [[thread_position_in_grid]],
        constant SparkSplat* splats [[buffer(0)]],
        constant uint& splatCount [[buffer(1)]],
        constant float4x4& modelMatrix [[buffer(2)]],
        constant float4x4& viewMatrix [[buffer(3)]],
        constant float4x4& projectionMatrix [[buffer(4)]],
        constant float2& drawableSize [[buffer(5)]],
        constant float& scale [[buffer(6)]],
        constant uint2& tileGridSize [[buffer(7)]],
        device atomic_uint* tileCounters [[buffer(8)]],
        device TileSplatIndex* tileSplatIndices [[buffer(9)]],
        device const uint* tileOffsets [[buffer(10)]],
        constant uint& maxTotalIntersections [[buffer(11)]],
        device TileProjectedSplat* projectedSplats [[buffer(12)]]
    ) {
        if (splatID >= splatCount) {
            return;
        }

        uint2 minTile, maxTile;
        float depth;
        TileProjectedSplat projected;

        if (!computeSplatTileBounds(splatID, splats, modelMatrix, viewMatrix,
                                     projectionMatrix, drawableSize, tileGridSize,
                                     minTile, maxTile, depth, projected)) {
            return;
        }

        projectedSplats[splatID] = projected;

        for (uint ty = minTile.y; ty <= maxTile.y; ty++) {
            for (uint tx = minTile.x; tx <= maxTile.x; tx++) {
                uint tileIndex = tileToLinearIndex(uint2(tx, ty), tileGridSize);

                // Atomic increment gives the local index within the tile.
                uint localIndex = atomic_fetch_add_explicit(&tileCounters[tileIndex], 1u, memory_order_relaxed);

                uint writeIndex = tileOffsets[tileIndex] + localIndex;

                // Bounds check against the total buffer size.
                if (writeIndex < maxTotalIntersections) {
                    tileSplatIndices[writeIndex].splatID = splatID;
                    tileSplatIndices[writeIndex].depth = depth;
                }
            }
        }
    }

} // namespace TileSplatBinning
