#import "GaussianSplatShaders.h"
#import "SparkSplatSupport.h"

#import <metal_stdlib>

using namespace metal;
using namespace SparkSplatSupport;

namespace SparkSplatRenderShader {

    struct VertexIn {
        float2 position [[attribute(0)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 splatUv;          // Relative position on splat ellipse
        float4 rgba;
    };

    typedef VertexOut FragmentIn;

    // Constants
    constant float MAX_STD_DEV = 2.8284271247;  // sqrt(8)
    constant float MIN_ALPHA = 0.5 / 255.0;
    constant float CLIP_XY = 1.4;
    constant float MAX_PIXEL_RADIUS = 512.0;

    // Function constants
    constant bool convert_srgb_to_linear [[function_constant(0)]];
    constant bool use_sh [[function_constant(1)]];

    // MARK: - Vertex Shader

    [[vertex]] VertexOut vertex_main(
        VertexIn in [[stage_in]],
        uint instance_id [[instance_id]],
        constant uint4 *packedSplats [[buffer(2)]],
        constant IndexedDistance *indexedDistances [[buffer(3)]],
        constant float4x4 &modelMatrix [[buffer(4)]],
        constant float4x4 &viewMatrix [[buffer(5)]],
        constant float4x4 &projectionMatrix [[buffer(6)]],
        constant float2 &drawableSize [[buffer(8)]],
        constant float &scale [[buffer(9)]],
        constant float3 &cameraPosition [[buffer(10)]],
        constant uint &shDegree [[buffer(11), function_constant(use_sh)]],
        device const float *shCoefficients [[buffer(12), function_constant(use_sh)]]
    ) {
        VertexOut out;
        // Default to outside frustum so it's discarded if we return early
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.splatUv = float2(0.0);
        out.rgba = float4(0.0);

        // Get sorted index
        uint splatIndex = indexedDistances[instance_id].index;

        // Fetch and unpack splat
        uint4 packed = packedSplats[splatIndex];

        float3 center, scales;
        float4 quaternion, rgba;
        unpackSplatEncoding(packed, center, scales, quaternion, rgba);

        // Cull by alpha
        if (rgba.a < MIN_ALPHA) {
            return out;
        }

        // Cull if all scales are zero
        if (scales.x == 0.0 && scales.y == 0.0 && scales.z == 0.0) {
            return out;
        }

        // Transform center to world space
        float4 worldCenter = modelMatrix * float4(center, 1.0);

        // Evaluate spherical harmonics for view-dependent color
        // Check shDegree > 0 as runtime toggle (0 = disabled)
        if (use_sh && shDegree > 0 && shCoefficients != nullptr) {
            float3 viewDir = normalize(worldCenter.xyz - cameraPosition);
            float3 shColor = evaluateSH(viewDir, shCoefficients, splatIndex, shDegree);
            rgba.rgb = clamp(rgba.rgb + shColor, 0.0, 1.0);
        }

        // Transform to view space
        float4 viewCenter4 = viewMatrix * worldCenter;
        float3 viewCenter = viewCenter4.xyz;

        // Cull splats behind camera
        if (viewCenter.z >= 0.0) {
            return out;
        }

        // Compute clip space center
        float4 clipCenter = projectionMatrix * float4(viewCenter, 1.0);

        // Cull outside near/far planes
        if (abs(clipCenter.z) >= clipCenter.w) {
            return out;
        }

        // Cull outside XY frustum
        float clip = CLIP_XY * clipCenter.w;
        if (abs(clipCenter.x) > clip || abs(clipCenter.y) > clip) {
            return out;
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

        // TODO: Make configurable
        // Add small blur for anti-aliasing
        float blurAmount = 0.3;
        float detOrig = cov2D.a * cov2D.d - cov2D.b * cov2D.b;
        cov2D.a += blurAmount;
        cov2D.d += blurAmount;
        float det = cov2D.a * cov2D.d - cov2D.b * cov2D.b;

        // Compute anti-aliasing intensity scaling
        float blurAdjust = sqrt(max(0.0, detOrig / det));
        rgba.a *= blurAdjust;

        if (rgba.a < MIN_ALPHA) {
            return out;
        }

        // Eigendecomposition and quad vertex computation
        Eigen2D eigen = eigendecompose2D(cov2D, MAX_PIXEL_RADIUS, MAX_STD_DEV);
        float3 ndcCenter = clipCenter.xyz / clipCenter.w;

        out.rgba = rgba;
        out.splatUv = in.position * MAX_STD_DEV;
        out.position = computeSplatQuadVertex(in.position, ndcCenter, eigen, drawableSize, clipCenter.w);

        return out;
    }

    // MARK: - Fragment Shader

    [[fragment]] float4 fragment_main(FragmentIn in [[stage_in]]) {
        float4 rgba = in.rgba;

        // Convert sRGB to linear for correct blending
        if (convert_srgb_to_linear) {
            rgba.rgb = pow(rgba.rgb, float3(2.2));
        }

        // Compute squared distance from center
        float z = dot(in.splatUv, in.splatUv);

        // Discard if beyond max standard deviations
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        // Apply Gaussian falloff
        rgba.a *= exp(-0.5 * z);

        // Discard if too transparent
        if (rgba.a < MIN_ALPHA) {
            discard_fragment();
        }

        // Output premultiplied alpha
        return float4(rgba.rgb * rgba.a, rgba.a);
    }

}; // namespace SparkSplatRenderShader
