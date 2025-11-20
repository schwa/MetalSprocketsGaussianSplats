#include <metal_stdlib>
using namespace metal;

namespace BlitShader {

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
        return texture.sample(s, in.texCoord);
    }

}
