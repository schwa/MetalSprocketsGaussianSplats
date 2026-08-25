#import "GaussianSplatDebugShaders.h"
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
        float2 splatUv;
        float4 rgba;
        ushort renderTargetArrayIndex [[render_target_array_index]];
    };

    struct DebugVertexOut {
        float4 position [[position]];
        float2 splatUv;
        float4 rgba;
        float3 worldPosition;
        float splatSize;
        float depth;
        float3 normal;
        float aspectRatio;
        uint cloudIndex;
        ushort renderTargetArrayIndex [[render_target_array_index]];
    };

    typedef VertexOut FragmentIn;
    typedef DebugVertexOut DebugFragmentIn;

    // MAX_STD_DEV and MIN_ALPHA come from the function constants below.
    constant float CLIP_XY = 1.4;
    constant float MAX_PIXEL_RADIUS = 512.0;

    constant bool convert_srgb_to_linear [[function_constant(0)]];
    constant bool use_sh [[function_constant(1)]];
    constant bool use_bounding_box [[function_constant(2)]];

    // Render tuning (blur reduction). SplatRenderTuning specializes these at
    // pipeline build. If the build does not provide them, they default to the
    // tuned values, so any pipeline gets the sharper and cheaper look without
    // extra wiring.
    constant float fc_max_std_dev [[function_constant(3)]];
    constant float fc_min_alpha   [[function_constant(4)]];
    constant float fc_blur_amount [[function_constant(5)]];
    constant float MAX_STD_DEV = is_function_constant_defined(fc_max_std_dev) ? fc_max_std_dev : 2.5;
    constant float MIN_ALPHA   = is_function_constant_defined(fc_min_alpha)   ? fc_min_alpha   : (2.0 / 255.0);
    constant float BLUR_AMOUNT = is_function_constant_defined(fc_blur_amount) ? fc_blur_amount : 0.05;

    // MARK: - Vertex Shader

    __attribute__((always_inline)) inline VertexOut vertex_common(
        VertexIn in,
        uint instance_id,
        ushort amplification_id,
        constant IndexedDistance *indexedDistances,
        constant float4x4 *viewMatrices,
        constant float4x4 *projectionMatrices,
        constant float2 &drawableSize,
        constant float &scale,
        constant float3 *cameraPositions,
        constant uint &shDegree,
        constant BoundingBox3D &boundingBox,
        constant MultiCloudArgumentBuffer &clouds
    ) {
        // amplification_id selects the matrices: 0 for mono, 0 or 1 for stereo.
        float4x4 viewMatrix = viewMatrices[amplification_id];
        float4x4 projectionMatrix = projectionMatrices[amplification_id];
        float3 cameraPosition = cameraPositions[amplification_id];
        VertexOut out;
        // Default outside the frustum, so an early return discards the vertex.
        out.position = float4(0.0, 0.0, 2.0, 1.0);
        out.splatUv = float2(0.0);
        out.rgba = float4(0.0);
        out.renderTargetArrayIndex = amplification_id;

        IndexedDistance indexedDistance = indexedDistances[instance_id];
        uint splatIndex = indexedDistance.splatIndex;
        ushort cloudIndex = indexedDistance.cloudIndex;

        if (cloudIndex >= clouds.cloudCount) {
            return out;
        }


        SplatCloudData cloudData = clouds.clouds[cloudIndex];
        device const SparkSplat* splats = cloudData.splats;
        float4x4 modelMatrix = cloudData.modelMatrix;
        float cloudOpacity = cloudData.opacity;

        SparkSplat splat = splats[splatIndex];

        float3 center = float3(splat.position);
        float3 scales = float3(splat.scale);
        float4 quaternion = float4(splat.rotation);
        float4 rgba = float4(splat.color) / 255.0;

        rgba.a *= cloudOpacity;

        if (rgba.a < MIN_ALPHA) {
            return out;
        }

        if (scales.x == 0.0 && scales.y == 0.0 && scales.z == 0.0) {
            return out;
        }

        // Cull by the bounding box in model space, before any transforms.
        if (use_bounding_box) {
            if (center.x < boundingBox.minBounds.x || center.x > boundingBox.maxBounds.x ||
                center.y < boundingBox.minBounds.y || center.y > boundingBox.maxBounds.y ||
                center.z < boundingBox.minBounds.z || center.z > boundingBox.maxBounds.z) {
                return out;
            }
        }

        float4 worldCenter = modelMatrix * float4(center, 1.0);

        // Evaluate the spherical harmonics for view-dependent color.
        if (use_sh && shDegree > 0) {
            device const float* shCoefficients = cloudData.shCoefficients;
            if (shCoefficients != nullptr) {
                float3 viewDir = normalize(worldCenter.xyz - cameraPosition);
                float3 shColor = evaluateSH(viewDir, shCoefficients, splatIndex, shDegree);
                rgba.rgb = clamp(rgba.rgb + shColor, 0.0, 1.0);
            }
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

        // Anti-aliasing covariance dilation (BLUR_AMOUNT px^2, from render tuning).
        float detOrig = cov2D.a * cov2D.d - cov2D.b * cov2D.b;
        cov2D.a += BLUR_AMOUNT;
        cov2D.d += BLUR_AMOUNT;
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

        return out;
    }

    [[vertex]] VertexOut vertex_main(
        VertexIn in [[stage_in]],
        uint instance_id [[instance_id]],
        ushort amplification_id [[amplification_id]],
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
        return vertex_common(in, instance_id, amplification_id, indexedDistances, viewMatrices, projectionMatrices, drawableSize, scale, cameraPositions, shDegree, boundingBox, clouds);
    }

    [[vertex]] DebugVertexOut vertex_debug(
        VertexIn in [[stage_in]],
        uint instance_id [[instance_id]],
        ushort amplification_id [[amplification_id]],
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
        VertexOut base = vertex_common(in, instance_id, amplification_id, indexedDistances, viewMatrices, projectionMatrices, drawableSize, scale, cameraPositions, shDegree, boundingBox, clouds);
        DebugVertexOut out;
        out.position = base.position;
        out.splatUv = base.splatUv;
        out.rgba = base.rgba;
        out.renderTargetArrayIndex = base.renderTargetArrayIndex;
        out.worldPosition = float3(0.0);
        out.splatSize = 0.0;
        out.depth = 0.0;
        out.normal = float3(0.0);
        out.aspectRatio = 1.0;
        out.cloudIndex = 0;

        IndexedDistance indexedDistance = indexedDistances[instance_id];
        if (indexedDistance.cloudIndex >= clouds.cloudCount) {
            return out;
        }
        SplatCloudData cloudData = clouds.clouds[indexedDistance.cloudIndex];
        SparkSplat splat = cloudData.splats[indexedDistance.splatIndex];
        float3 scales = float3(splat.scale);
        float4 quaternion = float4(splat.rotation);
        float4 worldCenter = cloudData.modelMatrix * float4(float3(splat.position), 1.0);
        float maxScale = max(scales.x, max(scales.y, scales.z));
        float minScale = min(scales.x, min(scales.y, scales.z));

        out.worldPosition = worldCenter.xyz;
        out.splatSize = maxScale;
        out.depth = -(viewMatrices[amplification_id] * worldCenter).z;
        out.normal = normalize((cloudData.modelMatrix * float4(quatVec(quaternion, float3(0.0, 0.0, 1.0)), 0.0)).xyz);
        out.aspectRatio = minScale > 0.0 ? maxScale / minScale : 1.0;
        out.cloudIndex = indexedDistance.cloudIndex;
        return out;
    }

    // MARK: - Fragment Shader

    [[fragment]] float4 fragment_main(FragmentIn in [[stage_in]]) {
        float4 rgba = in.rgba;

        // Convert sRGB to linear for correct blending.
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

        // Premultiplied alpha.
        return float4(rgba.rgb * rgba.a, rgba.a);
    }

    // MARK: - Debug Helper: Heat Map Color

    /// Converts a normalized value (0-1) to a heat map color: blue to cyan to green to yellow to red.
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

    /// Colorizes splats by their distance from the cloud center.
    [[fragment]] float4 fragment_debug_distance(
        DebugFragmentIn in [[stage_in]],
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

    /// Colorizes splats by their size (max scale).
    [[fragment]] float4 fragment_debug_size(
        DebugFragmentIn in [[stage_in]],
        constant DebugSizeParams &params [[buffer(0)]]
    ) {
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

    /// Colorizes splats by their depth (distance from the camera).
    [[fragment]] float4 fragment_debug_depth(
        DebugFragmentIn in [[stage_in]],
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

    /// Colorizes splats by their opacity value.
    [[fragment]] float4 fragment_debug_opacity(
        DebugFragmentIn in [[stage_in]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        // Use the original rgba.a, before the Gaussian falloff.
        float t = clamp(in.rgba.a, 0.0, 1.0);
        float3 color = heatMapColor(t);

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Normal

    /// Colorizes splats by their normal direction.
    [[fragment]] float4 fragment_debug_normal(
        DebugFragmentIn in [[stage_in]]
    ) {
        float z = dot(in.splatUv, in.splatUv);
        if (z > (MAX_STD_DEV * MAX_STD_DEV)) {
            discard_fragment();
        }

        float alpha = in.rgba.a * exp(-0.5 * z);
        if (alpha < MIN_ALPHA) {
            discard_fragment();
        }

        // Map the normal from [-1,1] to [0,1] for RGB.
        float3 color = in.normal * 0.5 + 0.5;

        return float4(color * alpha, alpha);
    }

    // MARK: - Debug Fragment Shader: Aspect Ratio

    /// Colorizes splats by their aspect ratio (elongation).
    [[fragment]] float4 fragment_debug_aspect_ratio(
        DebugFragmentIn in [[stage_in]],
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

    /// Generates a distinct color for each cloud index with golden-ratio hue spacing.
    inline float3 cloudIndexColor(uint index, uint count) {
        // The golden ratio distributes the hues evenly.
        float goldenRatio = 0.618033988749895;
        float hue = fract(float(index) * goldenRatio);
        
        // Convert HSV to RGB (saturation = 0.8, value = 1.0).
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

    /// Colorizes splats by the cloud they belong to.
    [[fragment]] float4 fragment_debug_cloud_index(
        DebugFragmentIn in [[stage_in]],
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

        // If the index is within bounds, use the custom color. Otherwise use magenta to show overflow.
        float3 color;
        if (in.cloudIndex < MAX_DEBUG_CLOUD_COLORS) {
            color = params.cloudColors[in.cloudIndex];
        } else {
            color = float3(1.0, 0.0, 1.0); // Magenta for overflow
        }

        return float4(color * alpha, alpha);
    }

}; // namespace SparkSplatRenderShader
