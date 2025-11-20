#include <metal_stdlib>
#include "GenericSplat.h"
#include "SOGSplatSupport.h"

using namespace metal;

namespace SOGToGenericSplatConversion {

[[kernel]] void sog_to_generic_splat(
    uint thread_id [[thread_position_in_grid]],
    texture2d<float, access::read> scalesTex [[texture(0)]],
    texture2d<float, access::read> quatsTex [[texture(1)]],
    texture2d<float, access::read> sh0Tex [[texture(2)]],
    constant float3* positions [[buffer(0)]],
    constant float* scalesCodebook [[buffer(1)]],
    constant float* sh0Codebook [[buffer(2)]],
    device GenericSplat* genericSplats [[buffer(3)]],
    constant uint& splatCount [[buffer(4)]],
    constant uint& textureWidth [[buffer(5)]]
) {
    if (thread_id >= splatCount) {
        return;
    }

    uint2 texCoord = uint2(thread_id % textureWidth, thread_id / textureWidth);
    float3 position = positions[thread_id];
    float3 scales = SOGSplatSupport::decodeScales(texCoord, scalesTex, scalesCodebook);
    float4 quaternion = SOGSplatSupport::decodeQuaternion(texCoord, quatsTex);
    float4 color = SOGSplatSupport::decodeColor(texCoord, sh0Tex, sh0Codebook);

    genericSplats[thread_id] = {
        .position = position,
        .scale = scales,
        .color = color,
        .rotation = quaternion
    };
}

} // namespace SOGToGenericSplatConversion
