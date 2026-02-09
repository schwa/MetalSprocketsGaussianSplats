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
        ushort renderTargetArrayIndex [[render_target_array_index]];
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
    constant bool use_bounding_box [[function_constant(2)]];

    // MARK: - Vertex Shader

    [[vertex]] VertexOut vertex_main(
        VertexIn in [[stage_in]],
        uint instance_id [[instance_id]],
        ushort amplification_id [[amplification_id]],
        ushort amplification_count [[amplification_count]],
        constant IndexedDistance *indexedDistances [[buffer(3)]],
        constant float4x4 *viewMatrices [[buffer(5)]],
        constant float4x4 *projectionMatrices [[buffer(6)]],
        constant float2 &drawableSize [[buffer(8)]],
        constant float &scale [[buffer(9)]],
        constant float3 *cameraPositions [[buffer(10)]],
        constant uint &shDegree [[buffer(11), function_constant(use_sh)]],
        constant BoundingBox3D &boundingBox [[buffer(12), function_constant(use_bounding_box)]],
        constant MultiCloudArgumentBuffer &clouds [[buffer(14)]]
    ) {
        // Select matrices based on amplification_id (0 for mono, 0/1 for stereo)
        float4x4 viewMatrix = viewMatrices[amplification_id];
        float4x4 projectionMatrix = projectionMatrices[amplification_id];
        float3 cameraPosition = cameraPositions[amplification_id];
        VertexOut out;
        // Default to outside frustum so it's discarded if we return early
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.splatUv = float2(0.0);
        out.rgba = float4(0.0);
        out.renderTargetArrayIndex = amplification_id;

        // Get sorted index and cloud index
        IndexedDistance indexedDistance = indexedDistances[instance_id];
        uint splatIndex = indexedDistance.splatIndex;
        ushort cloudIndex = indexedDistance.cloudIndex;

        // Bounds check cloud index
        if (cloudIndex >= clouds.cloudCount) {
            return out;
        }

        // Get per-cloud data from argument buffer
        SplatCloudData cloudData = clouds.clouds[cloudIndex];
        device const SparkSplat* splats = cloudData.splats;
        float4x4 modelMatrix = cloudData.modelMatrix;
        float cloudOpacity = cloudData.opacity;

        // Fetch splat
        SparkSplat splat = splats[splatIndex];

        float3 center = float3(splat.position);
        float3 scales = float3(splat.scale);
        float4 quaternion = float4(splat.rotation);
        float4 rgba = float4(splat.color) / 255.0;

        // Apply cloud-level opacity
        rgba.a *= cloudOpacity;

        // Cull by alpha
        if (rgba.a < MIN_ALPHA) {
            return out;
        }

        // Cull if all scales are zero
        if (scales.x == 0.0 && scales.y == 0.0 && scales.z == 0.0) {
            return out;
        }

        // Cull by bounding box (model space, before any transforms)
        if (use_bounding_box) {
            if (center.x < boundingBox.minBounds.x || center.x > boundingBox.maxBounds.x ||
                center.y < boundingBox.minBounds.y || center.y > boundingBox.maxBounds.y ||
                center.z < boundingBox.minBounds.z || center.z > boundingBox.maxBounds.z) {
                return out;
            }
        }

        // Transform center to world space
        float4 worldCenter = modelMatrix * float4(center, 1.0);

        // Evaluate spherical harmonics for view-dependent color
        if (use_sh && shDegree > 0) {
            device const float* shCoefficients = cloudData.shCoefficients;
            if (shCoefficients != nullptr) {
                float3 viewDir = normalize(worldCenter.xyz - cameraPosition);
                float3 shColor = evaluateSH(viewDir, shCoefficients, splatIndex, shDegree);
                rgba.rgb = clamp(rgba.rgb + shColor, 0.0, 1.0);
            }
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
