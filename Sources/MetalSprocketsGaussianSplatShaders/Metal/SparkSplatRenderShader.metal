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
        float3 worldPosition;    // World-space position of the splat center (for debug shaders)
        float splatSize;         // Maximum scale of the splat (for debug shaders)
        float depth;             // View-space depth (for debug shaders)
        float3 normal;           // World-space normal direction (for debug shaders)
        float aspectRatio;       // Ratio of max to min scale (for debug shaders)
        uint cloudIndex;         // Which cloud this splat belongs to (for debug shaders)
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
        out.worldPosition = float3(0.0);
        out.splatSize = 0.0;
        out.depth = 0.0;
        out.normal = float3(0.0);
        out.aspectRatio = 1.0;
        out.cloudIndex = 0;
        out.renderTargetArrayIndex = amplification_id;

        // Get sorted index and cloud index
        IndexedDistance indexedDistance = indexedDistances[instance_id];
        uint splatIndex = indexedDistance.splatIndex;
        ushort cloudIndex = indexedDistance.cloudIndex;

        // Bounds check cloud index
        if (cloudIndex >= clouds.cloudCount) {
            return out;
        }

        // Store cloud index for debug shaders
        out.cloudIndex = cloudIndex;

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

        // Store debug values for fragment shaders
        float maxScale = max(scales.x, max(scales.y, scales.z));
        float minScale = min(scales.x, min(scales.y, scales.z));
        out.splatSize = maxScale;
        out.aspectRatio = (minScale > 0.0) ? (maxScale / minScale) : 1.0;
        
        // Compute normal from quaternion (local Z axis transformed to world space)
        float3 localNormal = float3(0.0, 0.0, 1.0);
        float3 modelNormal = quatVec(quaternion, localNormal);
        out.normal = normalize((modelMatrix * float4(modelNormal, 0.0)).xyz);

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

        // Store world position for debug fragment shaders
        out.worldPosition = worldCenter.xyz;

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

        // Store depth for debug shaders (negative z in view space = positive depth)
        out.depth = -viewCenter.z;

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

    // MARK: - Debug Helper: Heat Map Color

    /// Convert a normalized value (0-1) to a heat map color (blue -> cyan -> green -> yellow -> red)
    inline float3 heatMapColor(float t) {
        t = clamp(t, 0.0, 1.0);
        if (t < 0.25) {
            return mix(float3(0.0, 0.0, 1.0), float3(0.0, 1.0, 1.0), t / 0.25);
        } else if (t < 0.5) {
            return mix(float3(0.0, 1.0, 1.0), float3(0.0, 1.0, 0.0), (t - 0.25) / 0.25);
        } else if (t < 0.75) {
            return mix(float3(0.0, 1.0, 0.0), float3(1.0, 1.0, 0.0), (t - 0.5) / 0.25);
        } else {
            return mix(float3(1.0, 1.0, 0.0), float3(1.0, 0.0, 0.0), (t - 0.75) / 0.25);
        }
    }

    // MARK: - Debug Fragment Shader: Distance from Cloud Center

    /// Fragment shader that colorizes splats by distance from cloud center
    [[fragment]] float4 fragment_debug_distance(
        FragmentIn in [[stage_in]],
        constant DebugDistanceParams &params [[buffer(0)]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        float distance = length(in.worldPosition - params.center);
        float t = clamp(distance / params.maxDistance, 0.0, 1.0);
        float3 color = heatMapColor(t);

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Splat Size

    /// Fragment shader that colorizes splats by their size (max scale)
    [[fragment]] float4 fragment_debug_size(
        FragmentIn in [[stage_in]],
        constant DebugSizeParams &params [[buffer(0)]]
    ) {
        // Debug logging
        if (in.position.x < 1 && in.position.y < 1) {
            os_log_default.log("fragment_debug_size: minSize=%f, maxSize=%f, splatSize=%f",
                params.minSize, params.maxSize, in.splatSize);
        }

        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        float range = params.maxSize - params.minSize;
        float t = (range > 0.0) ? clamp((in.splatSize - params.minSize) / range, 0.0, 1.0) : 0.5;
        float3 color = heatMapColor(t);

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Depth

    /// Fragment shader that colorizes splats by their depth (distance from camera)
    [[fragment]] float4 fragment_debug_depth(
        FragmentIn in [[stage_in]],
        constant DebugDepthParams &params [[buffer(0)]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        float range = params.maxDepth - params.minDepth;
        float t = (range > 0.0) ? clamp((in.depth - params.minDepth) / range, 0.0, 1.0) : 0.5;
        float3 color = heatMapColor(t);

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Opacity

    /// Fragment shader that colorizes splats by their opacity value
    [[fragment]] float4 fragment_debug_opacity(
        FragmentIn in [[stage_in]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        // Use the original rgba.a (before gaussian falloff) for visualization
        float t = clamp(in.rgba.a, 0.0, 1.0);
        float3 color = heatMapColor(t);

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Normal

    /// Fragment shader that colorizes splats by their normal direction
    [[fragment]] float4 fragment_debug_normal(
        FragmentIn in [[stage_in]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        // Map normal from [-1,1] to [0,1] for RGB visualization
        float3 color = in.normal * 0.5 + 0.5;

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Aspect Ratio

    /// Fragment shader that colorizes splats by their aspect ratio (elongation)
    [[fragment]] float4 fragment_debug_aspect_ratio(
        FragmentIn in [[stage_in]],
        constant DebugAspectRatioParams &params [[buffer(0)]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        float range = params.maxRatio - params.minRatio;
        float t = (range > 0.0) ? clamp((in.aspectRatio - params.minRatio) / range, 0.0, 1.0) : 0.5;
        float3 color = heatMapColor(t);

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Cloud Index

    /// Generate a distinct color for each cloud index using golden ratio hue spacing
    inline float3 cloudIndexColor(uint index, uint count) {
        // Use golden ratio for well-distributed hues
        float goldenRatio = 0.618033988749895;
        float hue = fract(float(index) * goldenRatio);
        
        // Convert HSV to RGB (saturation = 0.8, value = 1.0)
        float saturation = 0.8;
        float value = 1.0;
        
        float c = value * saturation;
        float x = c * (1.0 - abs(fmod(hue * 6.0, 2.0) - 1.0));
        float m = value - c;
        
        float3 rgb;
        if (hue < 1.0/6.0) {
            rgb = float3(c, x, 0);
        } else if (hue < 2.0/6.0) {
            rgb = float3(x, c, 0);
        } else if (hue < 3.0/6.0) {
            rgb = float3(0, c, x);
        } else if (hue < 4.0/6.0) {
            rgb = float3(0, x, c);
        } else if (hue < 5.0/6.0) {
            rgb = float3(x, 0, c);
        } else {
            rgb = float3(c, 0, x);
        }
        
        return rgb + m;
    }

    /// Fragment shader that colorizes splats by which cloud they belong to
    [[fragment]] float4 fragment_debug_cloud_index(
        FragmentIn in [[stage_in]],
        constant DebugCloudIndexParams &params [[buffer(0)]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        // Use custom color if index is within bounds, otherwise magenta to indicate overflow
        float3 color;
        if (in.cloudIndex < MAX_DEBUG_CLOUD_COLORS) {
            color = params.cloudColors[in.cloudIndex];
        } else {
            color = float3(1.0, 0.0, 1.0); // Magenta for overflow
        }

        return float4(color * alpha, alpha);
    }

}; // namespace SparkSplatRenderShader
