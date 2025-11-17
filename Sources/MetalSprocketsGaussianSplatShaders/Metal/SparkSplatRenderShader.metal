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
        constant float &scale [[buffer(9)]]
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

        // Extract rotation from model and view matrices and apply to quaternion
        // For now, assume model matrix is identity rotation (just translation/scale)
        // The viewMatrix transforms from world to view space

        // Compute view space quaternion of splat
        // We need to rotate the splat's orientation by the view rotation
        // Extract the rotation part of the view matrix
        float3x3 viewRotation = float3x3(
            viewMatrix[0].xyz,
            viewMatrix[1].xyz,
            viewMatrix[2].xyz
        );

        // Convert quaternion to matrix, apply view rotation
        float3x3 RS = scaleQuaternionToMatrix(scales, quaternion);

        // Apply view rotation to the RS matrix
        float3x3 viewRS = viewRotation * float3x3(modelMatrix[0].xyz, modelMatrix[1].xyz, modelMatrix[2].xyz) * RS;

        // Compute 3D covariance in view space
        float3x3 cov3D = viewRS * transpose(viewRS);

        // Compute Jacobian of projection
        float2 focal = 0.5 * drawableSize * float2(projectionMatrix[0][0], projectionMatrix[1][1]);

        float invZ = 1.0 / viewCenter.z;
        float2 J1 = focal * invZ;
        float2 J2 = -(J1 * viewCenter.xy) * invZ;

        float3x3 J = float3x3(
            float3(J1.x, 0.0, J2.x),
            float3(0.0, J1.y, J2.y),
            float3(0.0, 0.0, 0.0)
        );

        // Project 3D covariance to 2D
        float3x3 cov2D = transpose(J) * cov3D * J;
        float a = cov2D[0][0];
        float d = cov2D[1][1];
        float b = cov2D[0][1];

        // Add small blur for anti-aliasing (optional pre-blur)
        float blurAmount = 0.3;
        float detOrig = a * d - b * b;
        a += blurAmount;
        d += blurAmount;
        float det = a * d - b * b;

        // Compute anti-aliasing intensity scaling
        float blurAdjust = sqrt(max(0.0, detOrig / det));
        rgba.a *= blurAdjust;

        if (rgba.a < MIN_ALPHA) {
            return out;
        }

        // Eigendecomposition of 2D covariance
        float eigenAvg = 0.5 * (a + d);
        float eigenDelta = sqrt(max(0.0, eigenAvg * eigenAvg - det));
        float eigen1 = eigenAvg + eigenDelta;
        float eigen2 = eigenAvg - eigenDelta;

        // Compute eigenvectors
        float2 eigenVec1 = normalize(float2((abs(b) < 0.001) ? 1.0 : b, eigen1 - a));
        float2 eigenVec2 = float2(eigenVec1.y, -eigenVec1.x);

        // Compute scales in pixels
        float scale1 = min(MAX_PIXEL_RADIUS, MAX_STD_DEV * sqrt(eigen1));
        float scale2 = min(MAX_PIXEL_RADIUS, MAX_STD_DEV * sqrt(eigen2));

        // Compute NDC center
        float3 ndcCenter = clipCenter.xyz / clipCenter.w;

        // Compute pixel offset based on quad vertex position
        float2 pixelOffset = in.position.x * eigenVec1 * scale1 + in.position.y * eigenVec2 * scale2;
        float2 ndcOffset = (2.0 / drawableSize) * pixelOffset;
        float3 ndc = float3(ndcCenter.xy + ndcOffset, ndcCenter.z);

        out.rgba = rgba;
        out.splatUv = in.position * MAX_STD_DEV;
        out.position = float4(ndc.xy * clipCenter.w, clipCenter.zw);

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
