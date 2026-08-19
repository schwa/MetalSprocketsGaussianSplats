#import "GaussianSplatShaders.h"
#import "SparkSplatRenderShader.h"
#import "SparkSplatSupport.h"
#import "TileSplatSupport.h"

#import <metal_stdlib>
#import <metal_imageblocks>

using namespace metal;
using namespace SparkSplatSupport;
using namespace TileSplatSupport;

// Debug mode: when enabled, draws a red border at the tile edges (x=0 or y=0 within the tile).
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

    /// Renders each pixel from the tile's sorted splat list.
    ///
    /// Writes the result to the imageblock for a later blit to the color
    /// attachment. The binning write kernel (#58) precomputes the per-splat
    /// projection data (screen center, conic, color) once per frame, so the
    /// loop here is a cheap conic evaluation.
    [[fragment]] FragmentOut tile_fragment(
        FragmentIn in [[stage_in]],
        constant TileProjectedSplat* projectedSplats [[buffer(0)]],
        device TileSplatIndex* tileSplatIndices [[buffer(1)]],
        device const uint* tileOffsets [[buffer(2)]],
        constant TileRenderUniforms& uniforms [[buffer(3)]],
        TileSplatImageblock imageblockIn [[imageblock_data(TileSplatImageblock)]],
        ushort2 pixelPositionInTile [[pixel_position_in_tile]],
        ushort2 pixelsPerTile [[pixels_per_tile]]
    ) {
        uint2 pixelCoord = uint2(in.position.xy);

        FragmentOut out;

        // Debug mode: draw a red border at the tile edges. Check this first,
        // before the bounds check.
        if (debugTileBorders && (pixelPositionInTile.x == 0 || pixelPositionInTile.y == 0)) {
            out.imageblock.color = half4(1.0, 0.0, 0.0, 1.0);
            return out;
        }

        if (pixelCoord.x >= uint(uniforms.drawableSize.x) ||
            pixelCoord.y >= uint(uniforms.drawableSize.y)) {
            out.imageblock.color = half4(0.0);
            return out;
        }

        uint2 tileCoord = pixelToTile(pixelCoord);
        uint tileIndex = tileToLinearIndex(tileCoord, uniforms.tileGridSize);

        uint startIndex = tileOffsets[tileIndex];
        uint endIndex = tileOffsets[tileIndex + 1];
        uint count = endIndex - startIndex;

        if (count == 0) {
            // Empty tile is transparent.
            out.imageblock.color = half4(0.0);
            return out;
        }

        float4 accumulatedColor = float4(0.0);
        float accumulatedAlpha = 0.0;

        // Pixel center in screen coordinates.
        float2 pixelPos = float2(pixelCoord) + 0.5;

        // Splats are already sorted by depth, so process them front-to-back.
        for (uint i = 0; i < count; i++) {
            TileSplatIndex idx = tileSplatIndices[startIndex + i];
            TileProjectedSplat projected = projectedSplats[idx.splatID];

            float2 delta = pixelPos - projected.centerConicAB.xy;

            // Squared Mahalanobis distance via the precomputed conic.
            float mahalanobis2 = projected.centerConicAB.z * delta.x * delta.x
                + 2.0 * projected.centerConicAB.w * delta.x * delta.y
                + projected.conicD * delta.y * delta.y;

            // Skip outside the Gaussian cutoff.
            if (mahalanobis2 > MAX_STD_DEV * MAX_STD_DEV) {
                continue;
            }

            float alpha = projected.colorAlpha.w * exp(-0.5 * mahalanobis2);

            if (alpha < MIN_ALPHA) {
                continue;
            }

            // Front-to-back alpha blending; the color is already linear.
            if (accumulateFrontToBack(float4(projected.colorAlpha.rgb, 1.0), alpha, accumulatedColor, accumulatedAlpha)) {
                break; // Early exit: the pixel is opaque enough.
            }
        }

        // Output linear color; the sRGB render target encodes it on store.
        // Re-encoding here double-encoded and washed the image out (#59).
        out.imageblock.color = half4(half3(accumulatedColor.rgb), half(accumulatedAlpha));
        return out;
    }

    // MARK: - Blit Shader: Imageblock to Color Attachment

    /// Reads from the imageblock and writes to the color attachment.
    [[fragment]] half4 tile_blit_fragment(
        FragmentIn in [[stage_in]],
        TileSplatImageblock imageblockIn [[imageblock_data(TileSplatImageblock)]],
        ushort2 pixelPositionInTile [[pixel_position_in_tile]],
        ushort2 pixelsPerTile [[pixels_per_tile]]
    ) {
        return imageblockIn.color;
    }

} // namespace TileSplatRender
