#include <metal_stdlib>
using namespace metal;

namespace BlitShader {

    // Enable when the sampled texture holds sRGB-encoded values and the
    // render target is an sRGB format (which encodes again on store).
    constant bool convert_srgb_to_linear [[function_constant(0)]];

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    [[vertex]] VertexOut vertex_main(uint vertexID [[vertex_id]]) {
        // Full-screen triangle
        float2 positions[3] = {
            float2(-1, -1),
            float2(3, -1),
            float2(-1, 3)
        };

        float2 texCoords[3] = {
            float2(0, 1),
            float2(2, 1),
            float2(0, -1)
        };

        VertexOut out;
        out.position = float4(positions[vertexID], 0, 1);
        out.texCoord = texCoords[vertexID];
        return out;
    }

    [[fragment]] float4 fragment_main(
        VertexOut in [[stage_in]],
        texture2d<float> texture [[texture(0)]]
    ) {
        constexpr sampler s(filter::linear);
        float4 color = texture.sample(s, in.texCoord);
        if (convert_srgb_to_linear) {
            // Color is premultiplied by coverage; unpremultiply before the
            // sRGB decode, then restore (#162).
            float alpha = max(color.a, 1e-5);
            float3 c = color.rgb / alpha;
            color.rgb = select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045) * alpha;
        }
        return color;
    }

}
