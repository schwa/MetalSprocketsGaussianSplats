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

    // Gaussians per culling group (issue #75, paper Sec. 3.5). Matches the
    // preprocess threadgroup size so one surviving group maps to one
    // threadgroup. Must match PointSplatResources.groupSize.
    constant uint GROUP_SIZE = 256;
    // NDC margin shared with the per-Gaussian cull in project().
    constant float NDC_CULL_MARGIN = 1.4;

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

    // Reconstructs a SparkSplat from its packed 18-byte form (issue #77).
    static SparkSplat gps_unpack_splat(GPSPackedSplat packed, constant GPSPackedSplatBounds &bounds) {
        SparkSplat splat;
        float3 t = float3(packed.position[0], packed.position[1], packed.position[2]) / 65535.0;
        splat.position = half3(bounds.positionMin + t * bounds.positionExtent);

        uint scaleBits = uint(packed.scale[0]) | (uint(packed.scale[1]) << 16);
        float3 logT = float3((scaleBits >> 20) & 0x3FFu, (scaleBits >> 10) & 0x3FFu, scaleBits & 0x3FFu) / 1023.0;
        splat.scale = half3(exp(bounds.logScaleMin + logT * bounds.logScaleExtent));

        // Smallest-three: the largest-magnitude component (made positive at
        // pack time) is reconstructed from the other three.
        uint rotationBits = uint(packed.rotation[0]) | (uint(packed.rotation[1]) << 16);
        uint maxIndex = rotationBits >> 30;
        const float limit = 0.7071067811865476;
        float3 abc = (float3((rotationBits >> 20) & 0x3FFu, (rotationBits >> 10) & 0x3FFu, rotationBits & 0x3FFu) / 1023.0 * 2.0 - 1.0) * limit;
        float w = sqrt(max(0.0, 1.0 - dot(abc, abc)));
        float4 q;
        switch (maxIndex) {
        case 0: q = float4(w, abc.x, abc.y, abc.z); break;
        case 1: q = float4(abc.x, w, abc.y, abc.z); break;
        case 2: q = float4(abc.x, abc.y, w, abc.z); break;
        default: q = float4(abc.x, abc.y, abc.z, w); break;
        }
        splat.rotation = half4(q);

        splat.color = uchar4(packed.color[0], packed.color[1], packed.color[2], packed.color[3]);
        return splat;
    }

    // Loads a splat from either storage format; `splats` aliases an array
    // of SparkSplat or GPSPackedSplat depending on `packedFlag`.
    static inline SparkSplat gps_load_splat(device const uchar *splats, uint index, uint packedFlag, constant GPSPackedSplatBounds &bounds) {
        if (packedFlag != 0) {
            return gps_unpack_splat(reinterpret_cast<device const GPSPackedSplat *>(splats)[index], bounds);
        }
        return reinterpret_cast<device const SparkSplat *>(splats)[index];
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

    // Hierarchical depth test (paper Sec. 3.5): a region is provably
    // occluded when the four pyramid texels covering its screen AABB are
    // all closer than its minimum possible depth. The pyramid stores the
    // *maximum* (farthest) visible depth per region, so this never falsely
    // culls: background texels hold the far plane. minPx/maxPx are in
    // native-resolution pixels.
    static bool depthAABBOccluded(float2 minPx, float2 maxPx, float minDepth, constant PointSplatUniforms &uniforms, texture2d<float, access::read> depthPyramid) {
        float2 size = float2(depthPyramid.get_width(), depthPyramid.get_height());
        minPx = clamp(minPx, float2(0.0), size - 1.0);
        maxPx = clamp(maxPx, float2(0.0), size - 1.0);

        float extent = max(maxPx.x - minPx.x, maxPx.y - minPx.y);
        uint lod = uint(clamp(ceil(log2(max(extent, 1.0))), 0.0, float(uniforms.pyramidLevels - 1)));
        uint2 base = uint2(minPx) >> lod;
        uint2 levelSize = max(uint2(size) >> lod, uint2(1));
        uint2 upper = min(base + 1, levelSize - 1);

        float d0 = depthPyramid.read(uint2(base.x, base.y), lod).r;
        float d1 = depthPyramid.read(uint2(upper.x, base.y), lod).r;
        float d2 = depthPyramid.read(uint2(base.x, upper.y), lod).r;
        float d3 = depthPyramid.read(uint2(upper.x, upper.y), lod).r;
        return max(max(d0, d1), max(d2, d3)) < minDepth;
    }

    static bool isOccluded(ProjectedGaussian projected, constant PointSplatUniforms &uniforms, texture2d<float, access::read> depthPyramid) {
        float s = float(max(uniforms.supersampling, 1u));
        float2 minPx = (projected.pixelMean - projected.radius) / s;
        float2 maxPx = (projected.pixelMean + projected.radius) / s;
        float minDepth = projected.viewDepth - 3.0 * projected.sigmaZ;
        return depthAABBOccluded(minPx, maxPx, minDepth, uniforms, depthPyramid);
    }

    // Group-level hierarchical culling (issue #75, paper Sec. 3.5).
    //
    // One-time per splat buffer: model-space AABB per group of GROUP_SIZE
    // consecutive Gaussians, expanded by 3 sigma of each Gaussian's largest
    // scale so the box conservatively contains the splatted points.
    kernel void pointSplatGroupBounds(device const uchar *splats [[buffer(0)]],
                                      device float4 *bounds [[buffer(1)]],
                                      constant uint &splatCount [[buffer(2)]],
                                      constant uint &packedFlag [[buffer(3)]],
                                      constant GPSPackedSplatBounds &packedBounds [[buffer(4)]],
                                      uint gid [[thread_position_in_grid]]) {
        uint groupCount = (splatCount + GROUP_SIZE - 1) / GROUP_SIZE;
        if (gid >= groupCount) {
            return;
        }
        uint start = gid * GROUP_SIZE;
        uint end = min(start + GROUP_SIZE, splatCount);
        float3 lo = float3(INFINITY);
        float3 hi = float3(-INFINITY);
        for (uint i = start; i < end; i++) {
            SparkSplat splat = gps_load_splat(splats, i, packedFlag, packedBounds);
            float3 position = float3(splat.position);
            float3 scales = float3(splat.scale);
            float pad = 3.0 * max(scales.x, max(scales.y, scales.z));
            lo = min(lo, position - pad);
            hi = max(hi, position + pad);
        }
        bounds[2 * gid + 0] = float4(lo, 0.0);
        bounds[2 * gid + 1] = float4(hi, 0.0);
    }

    // Per frame, before the preprocess: zero the per-Gaussian counts (the
    // group-culled preprocess no longer touches every Gaussian), reset the
    // rendered mask on phase 1, and reset the visible-group counter.
    kernel void pointSplatClearCounts(device uint *counts [[buffer(0)]],
                                      device uint *renderedMask [[buffer(1)]],
                                      device uint *visibleGroupCount [[buffer(2)]],
                                      constant PointSplatUniforms &uniforms [[buffer(3)]],
                                      uint gid [[thread_position_in_grid]]) {
        if (gid == 0) {
            visibleGroupCount[0] = 0;
        }
        if (gid >= uniforms.splatCount) {
            return;
        }
        counts[gid] = 0;
        if (uniforms.occlusionPhase <= 1) {
            renderedMask[gid] = 0;
        }
    }

    // One thread per group: transform the AABB's 8 corners and cull the
    // whole group when it is provably behind the near plane, outside the
    // frustum (same 1.4 NDC margin as the per-Gaussian cull), or occluded
    // by the depth pyramid. Survivors are compacted into visibleGroups.
    // All tests are conservative: any doubt (e.g. a corner behind the
    // camera making the projected AABB unbounded) keeps the group.
    kernel void pointSplatGroupCull(device const float4 *bounds [[buffer(0)]],
                                    device uint *visibleGroups [[buffer(1)]],
                                    device atomic_uint *visibleGroupCount [[buffer(2)]],
                                    constant PointSplatUniforms &uniforms [[buffer(3)]],
                                    constant uint &groupCount [[buffer(4)]],
                                    texture2d<float, access::read> depthPyramid [[texture(0)]],
                                    uint gid [[thread_position_in_grid]]) {
        if (gid >= groupCount) {
            return;
        }
        float3 lo = bounds[2 * gid + 0].xyz;
        float3 hi = bounds[2 * gid + 1].xyz;

        bool anyInFront = false;
        bool allOutLeft = true;
        bool allOutRight = true;
        bool allOutTop = true;
        bool allOutBottom = true;
        bool projectionBounded = true;
        float2 minNDC = float2(INFINITY);
        float2 maxNDC = float2(-INFINITY);
        float minDepth = INFINITY;

        for (uint c = 0; c < 8; c++) {
            float3 corner = float3((c & 1) ? hi.x : lo.x, (c & 2) ? hi.y : lo.y, (c & 4) ? hi.z : lo.z);
            float4 world = uniforms.modelMatrix * float4(corner, 1.0);
            float3 view = (uniforms.viewMatrix * world).xyz;
            minDepth = min(minDepth, -view.z);
            if (-view.z > uniforms.nearPlane) {
                anyInFront = true;
            }
            float4 clip = uniforms.projectionMatrix * float4(view, 1.0);
            if (clip.w <= 0.0) {
                // Corner behind the camera: the projected footprint is not
                // bounded by the corner projections. Disable the NDC tests.
                projectionBounded = false;
                continue;
            }
            float2 ndc = clip.xy / clip.w;
            allOutLeft = allOutLeft && (ndc.x < -NDC_CULL_MARGIN);
            allOutRight = allOutRight && (ndc.x > NDC_CULL_MARGIN);
            allOutBottom = allOutBottom && (ndc.y < -NDC_CULL_MARGIN);
            allOutTop = allOutTop && (ndc.y > NDC_CULL_MARGIN);
            minNDC = min(minNDC, ndc);
            maxNDC = max(maxNDC, ndc);
        }

        if (!anyInFront) {
            return;
        }
        if (projectionBounded && (allOutLeft || allOutRight || allOutTop || allOutBottom)) {
            return;
        }
        if (uniforms.occlusionPhase != 0 && projectionBounded) {
            // NDC (y up) -> native-resolution pixels (y down).
            float2 size = float2(depthPyramid.get_width(), depthPyramid.get_height());
            float2 minPx = float2((minNDC.x * 0.5 + 0.5) * size.x, (0.5 - maxNDC.y * 0.5) * size.y);
            float2 maxPx = float2((maxNDC.x * 0.5 + 0.5) * size.x, (0.5 - minNDC.y * 0.5) * size.y);
            if (depthAABBOccluded(minPx, maxPx, max(minDepth, uniforms.nearPlane), uniforms, depthPyramid)) {
                return;
            }
        }
        uint slot = atomic_fetch_add_explicit(visibleGroupCount, 1u, memory_order_relaxed);
        visibleGroups[slot] = gid;
    }

    // Single thread: indirect dispatch arguments for the preprocess — one
    // threadgroup per surviving group.
    kernel void pointSplatGroupDispatchArgs(device const uint *visibleGroupCount [[buffer(0)]],
                                            device uint3 *args [[buffer(1)]],
                                            uint gid [[thread_position_in_grid]]) {
        if (gid != 0) {
            return;
        }
        args[0] = uint3(visibleGroupCount[0], 1, 1);
    }

    // Per Gaussian, dispatched indirectly with one threadgroup per
    // *surviving* culling group (issue #75): cull, project, Poisson-sample
    // the opacity-corrected point count (paper Secs. 3.3-3.4), write counts
    // for the distributor, and cache the packed (SH-evaluated) color for
    // the splat stage. Counts and renderedMask are pre-cleared by
    // pointSplatClearCounts; renderedMask records phase-1 participation so
    // phase 2 only considers Gaussians the stale pyramid culled.
    kernel void pointSplatPreprocess(device const uchar *splats [[buffer(0)]],
                                     device uint *counts [[buffer(1)]],
                                     constant PointSplatUniforms &uniforms [[buffer(2)]],
                                     device const float *shCoefficients [[buffer(3)]],
                                     device ulong *colors [[buffer(4)]],
                                     device uint *renderedMask [[buffer(5)]],
                                     device const uint *visibleGroups [[buffer(6)]],
                                     constant GPSPackedSplatBounds &packedBounds [[buffer(7)]],
                                     texture2d<float, access::read> depthPyramid [[texture(0)]],
                                     uint groupId [[threadgroup_position_in_grid]],
                                     uint lid [[thread_position_in_threadgroup]]) {
        uint gid = visibleGroups[groupId] * GROUP_SIZE + lid;
        if (gid >= uniforms.splatCount) {
            return;
        }
        if (uniforms.occlusionPhase > 1 && renderedMask[gid] != 0) {
            // Already rendered in phase 1.
            return;
        }

        SparkSplat splat = gps_load_splat(splats, gid, uniforms.packedSplats, packedBounds);
        ProjectedGaussian projected = project(splat, uniforms);
        if (!projected.valid) {
            return;
        }

        if (uniforms.occlusionPhase != 0 && isOccluded(projected, uniforms, depthPyramid)) {
            return;
        }

        // SH color depends only on the view direction to the Gaussian's
        // mean, so evaluate once here rather than per point.
        float3 rgb = float3(splat.color.xyz) / 255.0;
        if (uniforms.shDegree > 0) {
            float3 worldCenter = (uniforms.modelMatrix * float4(float3(splat.position), 1.0)).xyz;
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
    kernel void pointSplatSplat(device const uchar *splats [[buffer(0)]],
                                device const uint *indices [[buffer(1)]],
                                device atomic_ulong *framebuffer [[buffer(2)]],
                                constant PointSplatUniforms &uniforms [[buffer(3)]],
                                device const uint *totals [[buffer(4)]],
                                device const ulong *framebufferRead [[buffer(5)]],
                                device const ulong *colors [[buffer(6)]],
                                constant GPSPackedSplatBounds &packedBounds [[buffer(7)]],
                                uint gid [[thread_position_in_grid]]) {
        // Dispatched over the full capacity; totals[0] is the actual thread
        // count written by the workload distributor on the GPU timeline.
        if (gid >= min(totals[0], uniforms.capacity)) {
            return;
        }
        uint gaussianIndex = indices[gid];
        ProjectedGaussian projected = project(gps_load_splat(splats, gaussianIndex, uniforms.packedSplats, packedBounds), uniforms);
        if (!projected.valid) {
            return;
        }

        ulong packed = (gps_pack_depth(projected.viewDepth, uniforms.nearPlane, uniforms.farPlane) << GPS_DEPTH_SHIFT)
            | colors[gaussianIndex];

        GPSUInt2 seed = gps_make_seed(gid, uniforms.frameSeed * 2654435761u + 1u);
        uint k = max(uniforms.pointsPerThread, 1u);
        for (uint p = 0; p < k; p++) {
            GPSFloat2 u = gps_pcg2d(&seed);
            // Stratify the angle across the thread's K samples (RFC 0005 §1,
            // cheap variant): jittered strata reduce radial clumping without
            // changing the corrected radial density. Threads keep independent
            // seeds, so no cross-thread alignment.
            float stratifiedAngle = (float(p) + u.y) / float(k);
            GPSFloat2 sample = gps_corrected_box_muller(u.x, stratifiedAngle, projected.opacity);

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
