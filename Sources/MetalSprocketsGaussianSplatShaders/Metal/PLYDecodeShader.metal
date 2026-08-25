#import "GaussianSplatShaders.h"

#import <metal_stdlib>

using namespace metal;

namespace PLYDecodeShader {

constant float SH_C0 = 0.28209479177387814;

inline float scalar(device const uchar *bytes, ulong offset, uint type) {
    switch (type) {
    case 0: return float(as_type<char>(bytes[offset]));
    case 1: return float(bytes[offset]);
    case 2: return float(as_type<short>(ushort(ushort(bytes[offset]) | (ushort(bytes[offset + 1]) << 8))));
    case 3: return float(ushort(bytes[offset]) | (ushort(bytes[offset + 1]) << 8));
    case 4: return float(as_type<int>(uint(bytes[offset]) | (uint(bytes[offset + 1]) << 8) | (uint(bytes[offset + 2]) << 16) | (uint(bytes[offset + 3]) << 24)));
    case 5: return float(uint(bytes[offset]) | (uint(bytes[offset + 1]) << 8) | (uint(bytes[offset + 2]) << 16) | (uint(bytes[offset + 3]) << 24));
    case 6: return as_type<float>(uint(bytes[offset]) | (uint(bytes[offset + 1]) << 8) | (uint(bytes[offset + 2]) << 16) | (uint(bytes[offset + 3]) << 24));
    default: return 0.0;
    }
}

inline float value(device const uchar *bytes, ulong record, device const int *offsets, device const uint *types, uint slot, float fallback) {
    return offsets[slot] < 0 ? fallback : scalar(bytes, record + ulong(offsets[slot]), types[slot]);
}

[[kernel]] void decode(
    uint index [[thread_position_in_grid]],
    constant PLYDecodeParams &params [[buffer(0)]],
    device const uchar *bytes [[buffer(1)]],
    device const int *offsets [[buffer(2)]],
    device const uint *types [[buffer(3)]],
    device SparkSplat *splatsOut [[buffer(4)]],
    device float *shOut [[buffer(5)]]) {
    if (index >= params.count) return;

    ulong record = params.bodyOffset + ulong(index) * params.recordStride;
    float3 position = float3(value(bytes, record, offsets, types, 0, 0), value(bytes, record, offsets, types, 1, 0), value(bytes, record, offsets, types, 2, 0));
    float3 scale = exp(float3(value(bytes, record, offsets, types, 3, 0), value(bytes, record, offsets, types, 4, 0), value(bytes, record, offsets, types, 5, 0)));

    float3 color = float3(1.0);
    if (offsets[6] >= 0 && offsets[7] >= 0 && offsets[8] >= 0) {
        color = clamp(float3(value(bytes, record, offsets, types, 6, 0), value(bytes, record, offsets, types, 7, 0), value(bytes, record, offsets, types, 8, 0)) * SH_C0 + 0.5, 0.0, 1.0);
    } else if (offsets[9] >= 0 && offsets[10] >= 0 && offsets[11] >= 0) {
        color = float3(value(bytes, record, offsets, types, 9, 0), value(bytes, record, offsets, types, 10, 0), value(bytes, record, offsets, types, 11, 0));
        if (any(color > 1.0)) color /= 255.0;
        color = clamp(color, 0.0, 1.0);
    }

    float alpha = offsets[12] >= 0 ? 1.0 / (1.0 + exp(-value(bytes, record, offsets, types, 12, 0))) : value(bytes, record, offsets, types, 13, 1.0);
    float4 rotation = normalize(float4(value(bytes, record, offsets, types, 15, 0), value(bytes, record, offsets, types, 16, 0), value(bytes, record, offsets, types, 17, 0), value(bytes, record, offsets, types, 14, 1)));

    SparkSplat splat;
    splat.position = half3(position);
    splat.scale = half3(scale);
    splat.color = uchar4(clamp(float4(color, alpha), 0.0, 1.0) * 255.0);
    splat.rotation = half4(rotation);
    splatsOut[index] = splat;

    uint coefficientCount = params.shCoefficientCount;
    for (uint coefficient = 0; coefficient < coefficientCount; coefficient++) {
        uint output = (index * coefficientCount + coefficient) * 3;
        shOut[output] = value(bytes, record, offsets, types, 18 + coefficient, 0);
        shOut[output + 1] = value(bytes, record, offsets, types, 18 + coefficientCount + coefficient, 0);
        shOut[output + 2] = value(bytes, record, offsets, types, 18 + coefficientCount * 2 + coefficient, 0);
    }
}

}
