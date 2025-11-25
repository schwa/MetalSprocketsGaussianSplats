#import "GaussianSplatShaders.h"
#import "SparkSplatRenderShader.h"
#import "SparkSplatSupport.h"
#import "TileSplatSupport.h"

#import <metal_stdlib>

using namespace metal;
using namespace SparkSplatSupport;
using namespace TileSplatSupport;

namespace TileSplatBinning {

    // MARK: - Tile Binning Compute Kernel

    /// Assigns each splat to all tiles it overlaps
    /// One thread per splat
    [[kernel]] void tile_binning(
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
        device TileSplatIndex* tileSplatIndices [[buffer(9)]]
    ) {
        if (splatID >= splatCount) {
            return;
        }

        // Fetch splat
        SparkSplat splat = splats[splatID];

        float3 center = float3(splat.position);
        float3 scales = float3(splat.scale);
        float4 quaternion = float4(splat.rotation);
        float4 rgba = float4(splat.color) / 255.0;

        // Cull by alpha
        if (rgba.a < MIN_ALPHA) {
            return;
        }

        // Cull if all scales are zero
        if (scales.x == 0.0 && scales.y == 0.0 && scales.z == 0.0) {
            return;
        }

        // Transform center to world space
        float4 worldCenter = modelMatrix * float4(center, 1.0);

        // Transform to view space
        float4 viewCenter4 = viewMatrix * worldCenter;
        float3 viewCenter = viewCenter4.xyz;

        // Cull splats behind camera
        if (viewCenter.z >= 0.0) {
            return;
        }

        // Store depth for sorting (negative Z, closer = more negative)
        float depth = viewCenter.z;

        // Compute clip space center
        float4 clipCenter = projectionMatrix * float4(viewCenter, 1.0);

        // Cull outside near/far planes
        if (abs(clipCenter.z) >= clipCenter.w) {
            return;
        }

        // Cull outside XY frustum
        float clip = CLIP_XY * clipCenter.w;
        if (abs(clipCenter.x) > clip || abs(clipCenter.y) > clip) {
            return;
        }

        // Build rotation-scale matrix and transform to view space
        float3x3 localRS = scaleQuaternionToMatrix(scales, quaternion);
        float3x3 viewRS = transformToViewSpace(modelMatrix, viewMatrix, localRS);

        // Compute 3D covariance in view space
        float3x3 cov3D = compute3DCovariance(viewRS);

        // Compute projection Jacobian and project to 2D
        float2 focal = computeFocalLength(projectionMatrix, drawableSize);
        float3x3 J = computeProjectionJacobian(viewCenter, focal);
        Covariance2D cov2D = projectCovarianceTo2D(cov3D, J);

        // Add small blur for anti-aliasing
        float blurAmount = 0.3;
        cov2D.a += blurAmount;
        cov2D.d += blurAmount;

        // Eigendecomposition for ellipse axes
        Eigen2D eigen = eigendecompose2D(cov2D, MAX_PIXEL_RADIUS, MAX_STD_DEV);

        // Compute NDC center
        float3 ndcCenter = clipCenter.xyz / clipCenter.w;

        // Compute bounding box in NDC space
        // The ellipse axes are in pixels, convert to NDC
        float2 majorAxisNDC = (2.0 / drawableSize) * eigen.majorAxis;
        float2 minorAxisNDC = (2.0 / drawableSize) * eigen.minorAxis;

        // Compute extent of ellipse in NDC
        float2 extent = abs(majorAxisNDC) + abs(minorAxisNDC);

        float2 ndcMin = ndcCenter.xy - extent;
        float2 ndcMax = ndcCenter.xy + extent;

        // Clamp to NDC space
        ndcMin = clamp(ndcMin, float2(-1.0), float2(1.0));
        ndcMax = clamp(ndcMax, float2(-1.0), float2(1.0));

        // Convert to tile coordinates
        uint2 minTile, maxTile;
        ndcBoundsToTiles(ndcMin, ndcMax, tileGridSize, minTile, maxTile);

        // Write to all overlapping tiles
        for (uint ty = minTile.y; ty <= maxTile.y; ty++) {
            for (uint tx = minTile.x; tx <= maxTile.x; tx++) {
                uint tileIndex = tileToLinearIndex(uint2(tx, ty), tileGridSize);

                // Atomic increment counter
                uint localIndex = atomic_fetch_add_explicit(
                    &tileCounters[tileIndex], 1u, memory_order_relaxed
                );

                // Write to tile buffer if not full (truncate at MAX_SPLATS_PER_TILE)
                if (localIndex < MAX_SPLATS_PER_TILE) {
                    uint writeIndex = getTileBaseIndex(tileIndex) + localIndex;
                    tileSplatIndices[writeIndex].splatID = splatID;
                    tileSplatIndices[writeIndex].depth = depth;
                }
                // Continue counting even if full (for diagnostics)
            }
        }
    }

} // namespace TileSplatBinning
