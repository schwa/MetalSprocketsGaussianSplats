#import "GaussianSplatShaders.h"
#import "SparkSplatSupport.h"

#import <metal_stdlib>

using namespace metal;
using namespace SparkSplatSupport;

namespace StochasticSplatRenderShader {

    struct VertexIn {
        float2 position [[attribute(0)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 splatUv;          // Relative position on splat ellipse
        float4 rgba;
        uint splatIndex;         // For hash entropy
        ushort renderTargetArrayIndex [[render_target_array_index]];
    };

    typedef VertexOut FragmentIn;

    constant float MAX_STD_DEV = 2.8284271247;  // sqrt(8)
    constant float MIN_ALPHA = 0.5 / 255.0;
    constant float CLIP_XY = 1.4;
    constant float MAX_PIXEL_RADIUS = 512.0;

    constant bool convert_srgb_to_linear [[function_constant(0)]];
    constant bool use_sh [[function_constant(1)]];
    constant bool use_blue_noise [[function_constant(2)]];

    // PCG hash for the fallback random generation.
    inline uint pcg_hash(uint input) {
        uint state = input * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }

    inline float hash_to_float(uint hash) {
        return float(hash) / float(0xFFFFFFFFu);
    }

    // MARK: - Vertex Shader

    [[vertex]] VertexOut vertex_main(
        VertexIn in [[stage_in]],
        uint instance_id [[instance_id]],
        ushort amplification_id [[amplification_id]],
        constant SparkSplat *splats [[buffer(2)]],
        constant float4x4 &modelMatrix [[buffer(4)]],
        constant float4x4 *viewMatrices [[buffer(5)]],
        constant float4x4 *projectionMatrices [[buffer(6)]],
        constant float2 &drawableSize [[buffer(8)]],
        constant float &scale [[buffer(9)]],
        constant float3 *cameraPositions [[buffer(10)]],
        constant uint &shDegree [[buffer(11), function_constant(use_sh)]],
        device const float *shCoefficients [[buffer(12), function_constant(use_sh)]]
    ) {
        float4x4 viewMatrix = viewMatrices[amplification_id];
        float4x4 projectionMatrix = projectionMatrices[amplification_id];
        float3 cameraPosition = cameraPositions[amplification_id];

        VertexOut out;
        // Default outside the frustum, so an early return discards the vertex.
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.splatUv = float2(0.0);
        out.rgba = float4(0.0);
        out.splatIndex = instance_id;
        out.renderTargetArrayIndex = amplification_id;

        // Stochastic rendering needs no sort, so use instance_id directly.
        uint splatIndex = instance_id;

        SparkSplat splat = splats[splatIndex];

        float3 center = float3(splat.position);
        float3 scales = float3(splat.scale);
        float4 quaternion = float4(splat.rotation);
        float4 rgba = float4(splat.color) / 255.0;

        if (rgba.a < MIN_ALPHA) {
            return out;
        }

        if (scales.x == 0.0 && scales.y == 0.0 && scales.z == 0.0) {
            return out;
        }

        float4 worldCenter = modelMatrix * float4(center, 1.0);

        // Evaluate the spherical harmonics for view-dependent color.
        if (use_sh && shDegree > 0 && shCoefficients != nullptr) {
            float3 viewDir = normalize(worldCenter.xyz - cameraPosition.xyz);
            float3 shColor = evaluateSH(viewDir, shCoefficients, splatIndex, shDegree);
            rgba.rgb = clamp(rgba.rgb + shColor, 0.0, 1.0);
        }

        float4 viewCenter4 = viewMatrix * worldCenter;
        float3 viewCenter = viewCenter4.xyz;

        // Cull splats behind the camera.
        if (viewCenter.z >= 0.0) {
            return out;
        }

        float4 clipCenter = projectionMatrix * float4(viewCenter, 1.0);

        // Cull outside the near and far planes.
        if (abs(clipCenter.z) >= clipCenter.w) {
            return out;
        }

        // Cull outside the XY frustum.
        float clip = CLIP_XY * clipCenter.w;
        if (abs(clipCenter.x) > clip || abs(clipCenter.y) > clip) {
            return out;
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

        // Anti-aliasing intensity scale.
        float blurAdjust = sqrt(max(0.0, detOrig / det));
        rgba.a *= blurAdjust;

        if (rgba.a < MIN_ALPHA) {
            return out;
        }

        Eigen2D eigen = eigendecompose2D(cov2D, MAX_PIXEL_RADIUS, MAX_STD_DEV);
        float3 ndcCenter = clipCenter.xyz / clipCenter.w;

        out.rgba = rgba;
        out.splatUv = in.position * MAX_STD_DEV;
        out.position = computeSplatQuadVertex(in.position, ndcCenter, eigen, drawableSize, clipCenter.w);
        out.splatIndex = splatIndex;

        return out;
    }

    // MARK: - Fragment Shader

    [[fragment]] float4 fragment_main(
        FragmentIn in [[stage_in]],
        constant uint &uTime [[buffer(0)]],
        constant float &alphaThreshold [[buffer(1)]],
        texture2d<float> blueNoiseTexture [[texture(0)]]
    ) {
        float4 rgba = in.rgba;

        // Convert sRGB to linear.
        if (convert_srgb_to_linear) {
            rgba.rgb = pow(rgba.rgb, float3(2.2));
        }

        float z = dot(in.splatUv, in.splatUv);

        // Discard beyond the maximum standard deviations.
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        // Gaussian falloff.
        rgba.a *= exp(-0.5 * z);

        if (rgba.a < MIN_ALPHA) {
            discard_fragment();
        }

        // Always accept high-alpha fragments, which reduces shimmer.
        if (rgba.a > alphaThreshold) {
            return float4(rgba.rgb, 1.0);
        }

        float rand;
        if (use_blue_noise) {
            // Blue-noise sampling with temporal variation. The time and splat
            // index offset the coordinate, so the pattern changes per frame.
            uint2 coord = uint2(in.position.xy);
            uint noiseSize = blueNoiseTexture.get_width();
            uint2 noiseCoord = (coord + uint2(uTime * 7, uTime * 13 + in.splatIndex)) % noiseSize;
            rand = blueNoiseTexture.read(noiseCoord).r;
        } else {
            // PCG hash method.
            uint2 coord = uint2(in.position.xy);
            uint hash = pcg_hash(coord.x + coord.y * 65536u + uTime * 16777216u + in.splatIndex);
            rand = hash_to_float(hash);
        }

        // Probabilistic accept or reject.
        if (rand < rgba.a) {
            return float4(rgba.rgb, 1.0);  // Opaque output
        } else {
            discard_fragment();
        }

        return float4(0.0); // Never reached
    }

}; // namespace StochasticSplatRenderShader
