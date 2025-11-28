#import "GaussianSplatShaders.h"
#import "SparkSplatRenderShader.h"
#import "SparkSplatSupport.h"
#import "TileSplatSupport.h"

#import <metal_stdlib>
#import <metal_imageblocks>

using namespace metal;
using namespace SparkSplatSupport;
using namespace TileSplatSupport;

// Debug mode: when enabled, draws red border at tile edges (x=0 or y=0 within tile)
constant bool debugTileBorders [[function_constant(0)]];

namespace TileSplatRender {

    // MARK: - Vertex/Fragment Structures

    struct VertexOut {
        float4 position [[position]];
    };

    typedef VertexOut FragmentIn;

    // MARK: - Fragment Output (imageblock only, no color)

    struct FragmentOut {
        TileSplatImageblock imageblock [[imageblock_data(TileSplatImageblock)]];
    };

    // MARK: - Vertex Shader (Full-Screen Quad)

    [[vertex]] VertexOut tile_vertex(
        uint vertex_id [[vertex_id]],
        constant float2* vertices [[buffer(0)]]
    ) {
        VertexOut out;
        out.position = float4(vertices[vertex_id], 0.0, 1.0);
        return out;
    }

    // MARK: - Tile Fragment Shader (writes to imageblock)

    /// Renders each pixel by iterating through the tile's sorted splat list
    /// Writes result to imageblock for later blit to color attachment
    [[fragment]] FragmentOut tile_fragment(
        FragmentIn in [[stage_in]],
        constant SparkSplat* splats [[buffer(0)]],
        device TileSplatIndex* tileSplatIndices [[buffer(1)]],
        device const uint* tileOffsets [[buffer(2)]],
        constant TileRenderUniforms& uniforms [[buffer(3)]],
        TileSplatImageblock imageblockIn [[imageblock_data(TileSplatImageblock)]],
        ushort2 pixelPositionInTile [[pixel_position_in_tile]],
        ushort2 pixelsPerTile [[pixels_per_tile]]
    ) {
        // Get pixel coordinate from fragment position
        uint2 pixelCoord = uint2(in.position.xy);

        FragmentOut out;

        // Debug mode: draw red border at tile edges (check first, before bounds check)
        if (debugTileBorders && (pixelPositionInTile.x == 0 || pixelPositionInTile.y == 0)) {
            out.imageblock.color = half4(1.0, 0.0, 0.0, 1.0);
            return out;
        }

        // Bounds check
        if (pixelCoord.x >= uint(uniforms.drawableSize.x) ||
            pixelCoord.y >= uint(uniforms.drawableSize.y)) {
            out.imageblock.color = half4(0.0);
            return out;
        }

        // Calculate tile index for this pixel
        uint2 tileCoord = pixelToTile(pixelCoord);
        uint tileIndex = tileToLinearIndex(tileCoord, uniforms.tileGridSize);

        // Get tile's range from offsets
        uint startIndex = tileOffsets[tileIndex];
        uint endIndex = tileOffsets[tileIndex + 1];
        uint count = endIndex - startIndex;

        if (count == 0) {
            // Empty tile - transparent
            out.imageblock.color = half4(0.0);
            return out;
        }

        // Initialize accumulation for front-to-back blending
        float4 accumulatedColor = float4(0.0);
        float accumulatedAlpha = 0.0;

        // Pixel center in screen coordinates
        float2 pixelPos = float2(pixelCoord) + 0.5;

        // Precompute focal length
        float2 focal = computeFocalLength(uniforms.projectionMatrix, uniforms.drawableSize);

        // Process splats front-to-back (already sorted by depth)
        for (uint i = 0; i < count; i++) {
            TileSplatIndex idx = tileSplatIndices[startIndex + i];
            SparkSplat splat = splats[idx.splatID];

            float3 center = float3(splat.position);
            float3 scales = float3(splat.scale);
            float4 quaternion = float4(splat.rotation);
            float4 rgba = float4(splat.color) / 255.0;

            // Skip if too transparent
            if (rgba.a < MIN_ALPHA) {
                continue;
            }

            // Transform to world then view space
            float4 worldCenter = uniforms.modelMatrix * float4(center, 1.0);
            float4 viewCenter4 = uniforms.viewMatrix * worldCenter;
            float3 viewCenter = viewCenter4.xyz;

            // Skip if behind camera (shouldn't happen after binning, but safety check)
            if (viewCenter.z >= 0.0) {
                continue;
            }

            // Compute clip space position
            float4 clipCenter = uniforms.projectionMatrix * float4(viewCenter, 1.0);
            float3 ndcCenter = clipCenter.xyz / clipCenter.w;

            // Convert NDC to screen coordinates (flip Y: NDC Y=-1 is bottom, screen Y=0 is top)
            float2 splatCenter2D = float2(
                (ndcCenter.x + 1.0) * 0.5 * uniforms.drawableSize.x,
                (1.0 - ndcCenter.y) * 0.5 * uniforms.drawableSize.y
            );

            // Build rotation-scale matrix and transform to view space
            float3x3 localRS = scaleQuaternionToMatrix(scales, quaternion);
            float3x3 viewRS = transformToViewSpace(uniforms.modelMatrix, uniforms.viewMatrix, localRS);

            // Compute 3D covariance and project to 2D
            float3x3 cov3D = compute3DCovariance(viewRS);
            float3x3 J = computeProjectionJacobian(viewCenter, focal);
            Covariance2D cov2D = projectCovarianceTo2D(cov3D, J);

            // Add blur for anti-aliasing
            float blurAmount = 0.3;
            float detOrig = cov2D.a * cov2D.d - cov2D.b * cov2D.b;
            cov2D.a += blurAmount;
            cov2D.d += blurAmount;
            float det = cov2D.a * cov2D.d - cov2D.b * cov2D.b;

            // Compute anti-aliasing intensity scaling
            float blurAdjust = sqrt(max(0.0, detOrig / det));
            float baseAlpha = rgba.a * blurAdjust;

            if (baseAlpha < MIN_ALPHA) {
                continue;
            }

            // Eigendecomposition for Gaussian evaluation
            Eigen2D eigen = eigendecompose2D(cov2D, MAX_PIXEL_RADIUS, MAX_STD_DEV);

            // Flip Y component of eigen axes to match screen coordinates (Y flipped from NDC)
            eigen.majorAxis.y = -eigen.majorAxis.y;
            eigen.minorAxis.y = -eigen.minorAxis.y;

            // Compute pixel's position relative to splat center
            float2 delta = pixelPos - splatCenter2D;

            // Transform delta to ellipse-aligned UV space
            float2 eigenVec1 = normalize(eigen.majorAxis);
            float2 eigenVec2 = float2(eigenVec1.y, -eigenVec1.x);

            float majorScale = length(eigen.majorAxis);
            float minorScale = length(eigen.minorAxis);

            // Avoid division by zero
            if (majorScale < 0.001 || minorScale < 0.001) {
                continue;
            }

            // UV in ellipse space
            float u = dot(delta, eigenVec1) / majorScale;
            float v = dot(delta, eigenVec2) / minorScale;

            // Squared distance in normalized ellipse space
            float z = u * u + v * v;

            // Skip if outside Gaussian cutoff
            if (z > 1.0) {
                continue;
            }

            // Evaluate Gaussian
            float zScaled = z * (MAX_STD_DEV * MAX_STD_DEV);
            float alpha = baseAlpha * exp(-0.5 * zScaled);

            if (alpha < MIN_ALPHA) {
                continue;
            }

            // Convert sRGB to linear for correct blending
            float3 linearRGB = pow(rgba.rgb, float3(2.2));

            // Front-to-back alpha blending
            if (accumulateFrontToBack(float4(linearRGB, 1.0), alpha, accumulatedColor, accumulatedAlpha)) {
                break; // Early exit - pixel is opaque enough
            }
        }

        // Convert back from linear to sRGB for output
        float3 srgbColor = pow(accumulatedColor.rgb, float3(1.0 / 2.2));

        // Output to imageblock with premultiplied alpha
        out.imageblock.color = half4(half3(srgbColor), half(accumulatedAlpha));
        return out;
    }

    // MARK: - Blit Shader: Imageblock to Color Attachment

    /// Reads from the imageblock and outputs to the color attachment (framebuffer)
    [[fragment]] half4 tile_blit_fragment(
        FragmentIn in [[stage_in]],
        TileSplatImageblock imageblockIn [[imageblock_data(TileSplatImageblock)]],
        ushort2 pixelPositionInTile [[pixel_position_in_tile]],
        ushort2 pixelsPerTile [[pixels_per_tile]]
    ) {
        // Read from imageblock and output to color attachment
        return imageblockIn.color;
    }

} // namespace TileSplatRender
