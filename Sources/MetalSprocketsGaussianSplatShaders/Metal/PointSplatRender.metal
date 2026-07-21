#import "GaussianSplatShaders.h"
#import "SparkSplatSupport.h"
#import "PointSplatShaders.h"
#import "PointSplatMath.h"

#import <metal_stdlib>

using namespace metal;
using namespace SparkSplatSupport;

// Sort-free stochastic point renderer (RFC 0003). Per frame: preprocess
// computes a Poisson-sampled point count per Gaussian; the workload
// distributor (PointSplatWorkload.metal) maps splat threads to Gaussians;
// the splat kernel scatters pixel-sized opaque points into a 64-bit
// depth+color buffer with atomic_min; resolve unpacks to a color texture.
//
// Supports SxS supersampling with K points per thread (paper Sec. 3.4:
// point counts are stochastically rounded to multiples of K, amortizing
// the per-Gaussian projection across K samples). Frustum cull only.

namespace PointSplatRender {

    constant float MIN_ALPHA = 1.0 / 255.0;
    constant float COVARIANCE_FLOOR = 0.3;

    struct ProjectedGaussian {
        float2 pixelMean;
        float viewDepth;      // positive distance in front of the camera
        float c0;             // Cholesky factors of the 2D covariance
        float c1;
        float c2;
        float3 conic;         // inverse covariance (a, b, d)
        float opacity;
        float radius;         // conservative screen radius (supersampled px)
        float sigmaZ;         // view-space depth standard deviation
        bool valid;
    };

    // Shared projection between preprocess and splat so both agree exactly.
    static ProjectedGaussian project(SparkSplat splat, constant PointSplatUniforms &uniforms) {
        ProjectedGaussian result;
        result.valid = false;

        float4 rgba = float4(splat.color) / 255.0;
        result.opacity = rgba.a;
        if (rgba.a < MIN_ALPHA) {
            return result;
        }

        float3 scales = float3(splat.scale);
        if (scales.x == 0.0 && scales.y == 0.0 && scales.z == 0.0) {
            return result;
        }

        float4 worldCenter = uniforms.modelMatrix * float4(float3(splat.position), 1.0);
        float3 viewCenter = (uniforms.viewMatrix * worldCenter).xyz;
        // Near cull; reference uses 0.2 view units.
        if (-viewCenter.z <= uniforms.nearPlane) {
            return result;
        }

        float4 clipCenter = uniforms.projectionMatrix * float4(viewCenter, 1.0);
        if (clipCenter.w <= 0.0) {
            return result;
        }
        float3 ndc = clipCenter.xyz / clipCenter.w;
        if (abs(ndc.x) > 1.4 || abs(ndc.y) > 1.4) {
            return result;
        }

        float3x3 localRS = scaleQuaternionToMatrix(scales, float4(splat.rotation));
        float3x3 viewRS = transformToViewSpace(uniforms.modelMatrix, uniforms.viewMatrix, localRS);
        float3x3 cov3D = compute3DCovariance(viewRS);
        float2 focal = computeFocalLength(uniforms.projectionMatrix, uniforms.drawableSize);
        float3x3 J = computeProjectionJacobian(viewCenter, focal);
        Covariance2D cov2D = projectCovarianceTo2D(cov3D, J);
        // The pixel-space y axis is flipped relative to NDC (texture origin
        // top-left). Reflecting y negates the covariance cross term:
        // Sigma' = S Sigma S with S = diag(1, -1).
        cov2D.b = -cov2D.b;

        // The +0.3 floor is in *output pixel* units; the supersampled
        // framebuffer scales areas by S^2 (paper renders at S x S).
        float floorScale = COVARIANCE_FLOOR * float(uniforms.supersampling * uniforms.supersampling);
        cov2D.a += floorScale;
        cov2D.d += floorScale;
        float det = cov2D.a * cov2D.d - cov2D.b * cov2D.b;
        if (det <= 0.0) {
            return result;
        }

        // Cholesky: Sigma = L L^T with L = [[c0, 0], [c1, c2]].
        result.c0 = sqrt(cov2D.a);
        result.c1 = cov2D.b / result.c0;
        result.c2 = sqrt(max(cov2D.d - result.c1 * result.c1, 0.0));

        float invDet = 1.0 / det;
        result.conic = float3(cov2D.d * invDet, -cov2D.b * invDet, cov2D.a * invDet);

        // Conservative bounds for occlusion culling: 3 sigma of the major
        // eigenvalue in screen space, 3 sigma of depth in view space.
        float eigenAvg = 0.5 * (cov2D.a + cov2D.d);
        float eigenDelta = sqrt(max(0.0, eigenAvg * eigenAvg - det));
        result.radius = 3.0 * sqrt(max(eigenAvg + eigenDelta, 0.0));
        result.sigmaZ = sqrt(max(cov3D[2][2], 0.0));

        // Metal texture convention: origin top-left, y down.
        result.pixelMean = float2((ndc.x * 0.5 + 0.5) * uniforms.drawableSize.x,
                                  (0.5 - ndc.y * 0.5) * uniforms.drawableSize.y);
        result.viewDepth = -viewCenter.z;
        result.valid = true;
        return result;
    }

    // Clears the 64-bit framebuffer to (far depth | background color).
    kernel void pointSplatClear(device ulong  *framebuffer [[buffer(0)]],
                                constant ulong &clearValue [[buffer(1)]],
                                constant uint  &pixelCount [[buffer(2)]],
                                uint gid [[thread_position_in_grid]]) {
        if (gid < pixelCount) {
            framebuffer[gid] = clearValue;
        }
    }

    // Hierarchical depth test (paper Sec. 3.5): a Gaussian is provably
    // occluded when the four pyramid texels covering its screen AABB are
    // all closer than its minimum possible depth. The pyramid stores the
    // *maximum* (farthest) visible depth per region, so this never falsely
    // culls: background texels hold the far plane.
    static bool isOccluded(ProjectedGaussian projected, constant PointSplatUniforms &uniforms, texture2d<float, access::read> depthPyramid) {
        float s = float(max(uniforms.supersampling, 1u));
        float2 minPx = (projected.pixelMean - projected.radius) / s;
        float2 maxPx = (projected.pixelMean + projected.radius) / s;
        float2 size = float2(depthPyramid.get_width(), depthPyramid.get_height());
        minPx = clamp(minPx, float2(0.0), size - 1.0);
        maxPx = clamp(maxPx, float2(0.0), size - 1.0);

        float extent = max(maxPx.x - minPx.x, maxPx.y - minPx.y);
        uint lod = uint(clamp(ceil(log2(max(extent, 1.0))), 0.0, float(uniforms.pyramidLevels - 1)));
        uint2 base = uint2(minPx) >> lod;
        uint2 levelSize = max(uint2(size) >> lod, uint2(1));
        uint2 upper = min(base + 1, levelSize - 1);

        float minDepth = projected.viewDepth - 3.0 * projected.sigmaZ;
        float d0 = depthPyramid.read(uint2(base.x, base.y), lod).r;
        float d1 = depthPyramid.read(uint2(upper.x, base.y), lod).r;
        float d2 = depthPyramid.read(uint2(base.x, upper.y), lod).r;
        float d3 = depthPyramid.read(uint2(upper.x, upper.y), lod).r;
        return max(max(d0, d1), max(d2, d3)) < minDepth;
    }

    // Per Gaussian: cull, project, Poisson-sample the opacity-corrected
    // point count (paper Secs. 3.3-3.4), write counts for the distributor,
    // and cache the packed (SH-evaluated) color for the splat stage.
    // renderedMask records phase-1 participation so phase 2 only considers
    // Gaussians the stale pyramid culled.
    kernel void pointSplatPreprocess(device const SparkSplat *splats [[buffer(0)]],
                                     device uint *counts [[buffer(1)]],
                                     constant PointSplatUniforms &uniforms [[buffer(2)]],
                                     device const float *shCoefficients [[buffer(3)]],
                                     device ulong *colors [[buffer(4)]],
                                     device uint *renderedMask [[buffer(5)]],
                                     texture2d<float, access::read> depthPyramid [[texture(0)]],
                                     uint gid [[thread_position_in_grid]]) {
        if (gid >= uniforms.splatCount) {
            return;
        }
        counts[gid] = 0;
        if (uniforms.occlusionPhase <= 1) {
            renderedMask[gid] = 0;
        } else if (renderedMask[gid] != 0) {
            // Already rendered in phase 1.
            return;
        }

        ProjectedGaussian projected = project(splats[gid], uniforms);
        if (!projected.valid) {
            return;
        }

        if (uniforms.occlusionPhase != 0 && isOccluded(projected, uniforms, depthPyramid)) {
            return;
        }

        // SH color depends only on the view direction to the Gaussian's
        // mean, so evaluate once here rather than per point.
        float3 rgb = float3(splats[gid].color.xyz) / 255.0;
        if (uniforms.shDegree > 0) {
            float3 worldCenter = (uniforms.modelMatrix * float4(float3(splats[gid].position), 1.0)).xyz;
            float3 viewDir = normalize(worldCenter - uniforms.cameraPosition);
            rgb = max(rgb + evaluateSH(viewDir, shCoefficients, gid, uniforms.shDegree), 0.0);
        }
        colors[gid] = gps_pack_color(rgb.r, rgb.g, rgb.b);

        // Expected point count: lambda = 2 pi sqrt(|Sigma|) Li2(alpha).
        float sqrtDet = projected.c0 * projected.c2;
        float lambda = 2.0 * GPS_PI * sqrtDet * gps_dilog(projected.opacity);

        GPSUInt2 seed = gps_make_seed(gid, uniforms.frameSeed);
        uint numPoints = gps_poisson(&seed, lambda);

        // Stochastically round to a multiple of K and emit *thread* counts;
        // each splat thread draws K points.
        uint k = max(uniforms.pointsPerThread, 1u);
        uint numThreads = numPoints;
        if (k > 1) {
            numThreads = uint(gps_stochastic_round(float(numPoints) / float(k), gps_pcg2d(&seed).x));
        }

        // Per-Gaussian clamp (paper Sec. 4.3): at most half the framebuffer.
        uint pixelCount = uint(uniforms.drawableSize.x) * uint(uniforms.drawableSize.y);
        counts[gid] = min(numThreads, pixelCount / (2 * k));
        if (uniforms.occlusionPhase == 1 && counts[gid] > 0) {
            renderedMask[gid] = 1;
        }
    }

    // Extracts a native-resolution view-space depth image from the 64-bit
    // framebuffer, taking the farthest subpixel per pixel (conservative for
    // the occlusion test; background subpixels hold the far plane).
    kernel void pointSplatDepthExtract(device const ulong *framebuffer [[buffer(0)]],
                                       constant PointSplatUniforms &uniforms [[buffer(1)]],
                                       texture2d<float, access::write> outDepth [[texture(0)]],
                                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outDepth.get_width() || gid.y >= outDepth.get_height()) {
            return;
        }
        uint s = max(uniforms.supersampling, 1u);
        uint stride = uint(uniforms.drawableSize.x);
        float depth = 0.0;
        for (uint dy = 0; dy < s; dy++) {
            for (uint dx = 0; dx < s; dx++) {
                ulong value = framebuffer[(gid.y * s + dy) * stride + (gid.x * s + dx)];
                depth = max(depth, gps_unpack_depth(value >> GPS_DEPTH_SHIFT, uniforms.nearPlane, uniforms.farPlane));
            }
        }
        outDepth.write(float4(depth, 0.0, 0.0, 0.0), gid);
    }

    // One 2x2 max-downsample step of the depth pyramid; src and dst are
    // single-mip texture views of adjacent levels.
    kernel void pointSplatDepthDownsample(texture2d<float, access::read> src [[texture(0)]],
                                          texture2d<float, access::write> dst [[texture(1)]],
                                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
            return;
        }
        uint2 base = gid * 2;
        uint2 limit = uint2(src.get_width() - 1, src.get_height() - 1);
        float d0 = src.read(min(base, limit)).r;
        float d1 = src.read(min(base + uint2(1, 0), limit)).r;
        float d2 = src.read(min(base + uint2(0, 1), limit)).r;
        float d3 = src.read(min(base + uint2(1, 1), limit)).r;
        dst.write(float4(max(max(d0, d1), max(d2, d3)), 0.0, 0.0, 0.0), gid);
    }

    // Per splat-thread: sample K points from the assigned Gaussian and
    // splat each with atomic_min. Requires MSL 3.1 + Apple9/Mac2.
    kernel void pointSplatSplat(device const SparkSplat *splats [[buffer(0)]],
                                device const uint *indices [[buffer(1)]],
                                device atomic_ulong *framebuffer [[buffer(2)]],
                                constant PointSplatUniforms &uniforms [[buffer(3)]],
                                device const uint *totals [[buffer(4)]],
                                device const ulong *framebufferRead [[buffer(5)]],
                                device const ulong *colors [[buffer(6)]],
                                uint gid [[thread_position_in_grid]]) {
        // Dispatched over the full capacity; totals[0] is the actual thread
        // count written by the workload distributor on the GPU timeline.
        if (gid >= min(totals[0], uniforms.capacity)) {
            return;
        }
        uint gaussianIndex = indices[gid];
        ProjectedGaussian projected = project(splats[gaussianIndex], uniforms);
        if (!projected.valid) {
            return;
        }

        ulong packed = (gps_pack_depth(projected.viewDepth, uniforms.nearPlane, uniforms.farPlane) << GPS_DEPTH_SHIFT)
            | colors[gaussianIndex];

        GPSUInt2 seed = gps_make_seed(gid, uniforms.frameSeed * 2654435761u + 1u);
        uint k = max(uniforms.pointsPerThread, 1u);
        for (uint p = 0; p < k; p++) {
            GPSFloat2 u = gps_pcg2d(&seed);
            GPSFloat2 sample = gps_corrected_box_muller(u.x, u.y, projected.opacity);

            float2 pixel = floor(float2(projected.pixelMean.x + projected.c0 * sample.x,
                                        projected.pixelMean.y + projected.c1 * sample.x + projected.c2 * sample.y));
            int x = int(pixel.x);
            int y = int(pixel.y);
            if (x < 0 || x >= int(uniforms.drawableSize.x) || y < 0 || y >= int(uniforms.drawableSize.y)) {
                continue;
            }

            // Rejection at the 3DGS truncation threshold: opacity * gaussian
            // weight below 1/255 never contributes in the reference rasterizer.
            float2 delta = projected.pixelMean - pixel;
            float gaussianWeight = exp(-0.5 * (projected.conic.x * delta.x * delta.x + 2.0 * projected.conic.y * delta.x * delta.y + projected.conic.z * delta.y * delta.y));
            if (projected.opacity * gaussianWeight < MIN_ALPHA) {
                continue;
            }

            uint index = uint(y) * uint(uniforms.drawableSize.x) + uint(x);
            // Early depth test avoids atomic contention for occluded points.
            // Metal's 64-bit atomics only support min/max (no load), so read
            // through a plain aliased view; a stale value only costs a
            // superfluous atomic_min, never correctness.
            if (framebufferRead[index] <= packed) {
                continue;
            }
            atomic_min_explicit(&framebuffer[index], packed, memory_order_relaxed);
        }
    }

    // Temporal reprojection (paper Sec. 3.6): during camera motion, warp
    // the previous accumulated frame into the new view using this frame's
    // depth, clamp against the 3x3 color neighborhood of the current frame
    // to limit ghosting, and EMA-blend with history weight 0.9.
    kernel void pointSplatReproject(device const ulong *framebuffer [[buffer(0)]],
                                    constant PointSplatUniforms &uniforms [[buffer(1)]],
                                    constant float4x4 &cameraToWorld [[buffer(2)]],
                                    constant float4x4 &previousViewProjection [[buffer(3)]],
                                    texture2d<float, access::read> currentFrame [[texture(0)]],
                                    texture2d<float, access::sample> history [[texture(1)]],
                                    texture2d<float, access::write> outTexture [[texture(2)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
            return;
        }
        float4 current = currentFrame.read(gid);

        // Minimal view depth across this pixel's subpixels (paper Sec. 3.6).
        uint s = max(uniforms.supersampling, 1u);
        uint stride = uint(uniforms.drawableSize.x);
        float depth = uniforms.farPlane;
        for (uint dy = 0; dy < s; dy++) {
            for (uint dx = 0; dx < s; dx++) {
                ulong value = framebuffer[(gid.y * s + dy) * stride + (gid.x * s + dx)];
                depth = min(depth, gps_unpack_depth(value >> GPS_DEPTH_SHIFT, uniforms.nearPlane, uniforms.farPlane));
            }
        }

        // Reconstruct the world position and project into the previous view.
        float width = float(outTexture.get_width());
        float height = float(outTexture.get_height());
        float ndcX = ((float(gid.x) + 0.5) / width) * 2.0 - 1.0;
        float ndcY = 0.5 - ((float(gid.y) + 0.5) / height);
        ndcY *= 2.0;
        float p00 = uniforms.projectionMatrix[0][0];
        float p11 = uniforms.projectionMatrix[1][1];
        float3 viewPos = float3(ndcX * depth / p00, ndcY * depth / p11, -depth);
        float4 world = cameraToWorld * float4(viewPos, 1.0);
        float4 previousClip = previousViewProjection * world;
        if (previousClip.w <= 0.0) {
            outTexture.write(current, gid);
            return;
        }
        float2 previousNDC = previousClip.xy / previousClip.w;
        float2 uv = float2(previousNDC.x * 0.5 + 0.5, 0.5 - previousNDC.y * 0.5);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            outTexture.write(current, gid);
            return;
        }
        constexpr sampler historySampler(filter::linear, address::clamp_to_edge);
        float4 reprojected = history.sample(historySampler, uv);

        // Clamp history to the current frame's 3x3 neighborhood color AABB.
        float3 colorMin = current.rgb;
        float3 colorMax = current.rgb;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                uint2 coord = uint2(clamp(int2(gid) + int2(dx, dy), int2(0), int2(width - 1, height - 1)));
                float3 neighbor = currentFrame.read(coord).rgb;
                colorMin = min(colorMin, neighbor);
                colorMax = max(colorMax, neighbor);
            }
        }
        reprojected.rgb = clamp(reprojected.rgb, colorMin, colorMax);

        outTexture.write(float4(mix(current.rgb, reprojected.rgb, 0.9), 1.0), gid);
    }

    // Unpacks the supersampled 64-bit framebuffer into a native-resolution
    // color texture with an S x S box filter (paper Sec. 3.1).
    kernel void pointSplatResolve(device const ulong *framebuffer [[buffer(0)]],
                                  constant PointSplatUniforms &uniforms [[buffer(1)]],
                                  texture2d<float, access::write> outTexture [[texture(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
            return;
        }
        uint s = max(uniforms.supersampling, 1u);
        uint stride = uint(uniforms.drawableSize.x);
        float3 color = float3(0.0);
        for (uint dy = 0; dy < s; dy++) {
            for (uint dx = 0; dx < s; dx++) {
                ulong value = framebuffer[(gid.y * s + dy) * stride + (gid.x * s + dx)];
                color += float3(gps_unpack_channel(value, 24), gps_unpack_channel(value, 12), gps_unpack_channel(value, 0));
            }
        }
        outTexture.write(float4(color / float(s * s), 1.0), gid);
    }

} // namespace PointSplatRender
