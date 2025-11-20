#include <metal_stdlib>
using namespace metal;

namespace TemporalAccumulationShader {

    [[kernel]] void blend(
        texture2d<float, access::read> currentFrame [[texture(0)]],
        texture2d<float, access::read> accumulationTexture [[texture(1)]],
        texture2d<float, access::write> outputTexture [[texture(2)]],
        constant float &blendFactor [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
            return;
        }

        float4 current = currentFrame.read(gid);
        float4 accum = accumulationTexture.read(gid);

        // Exponential moving average
        float4 result = mix(accum, current, blendFactor);

        outputTexture.write(result, gid);
    }

}
