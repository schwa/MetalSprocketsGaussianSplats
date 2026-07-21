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
// v1 scope: 1x1 supersampling, K = 1 point per thread, frustum cull only.

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

        cov2D.a += COVARIANCE_FLOOR;
        cov2D.d += COVARIANCE_FLOOR;
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

    // Per Gaussian: cull, project, Poisson-sample the opacity-corrected
    // point count (paper Secs. 3.3-3.4), write counts for the distributor.
    kernel void pointSplatPreprocess(device const SparkSplat *splats [[buffer(0)]],
                                     device uint *counts [[buffer(1)]],
                                     constant PointSplatUniforms &uniforms [[buffer(2)]],
                                     uint gid [[thread_position_in_grid]]) {
        if (gid >= uniforms.splatCount) {
            return;
        }
        counts[gid] = 0;

        ProjectedGaussian projected = project(splats[gid], uniforms);
        if (!projected.valid) {
            return;
        }

        // Expected point count: lambda = 2 pi sqrt(|Sigma|) Li2(alpha).
        float sqrtDet = projected.c0 * projected.c2;
        float lambda = 2.0 * GPS_PI * sqrtDet * gps_dilog(projected.opacity);

        GPSUInt2 seed = gps_make_seed(gid, uniforms.frameSeed);
        uint numPoints = gps_poisson(&seed, lambda);

        // Per-Gaussian clamp (paper Sec. 4.3): at most half the framebuffer.
        uint pixelCount = uint(uniforms.drawableSize.x) * uint(uniforms.drawableSize.y);
        counts[gid] = min(numPoints, pixelCount / 2);
    }

    // Per point-thread: sample one point from the assigned Gaussian and
    // splat it with atomic_min. Requires MSL 3.1 + Apple9/Mac2.
    kernel void pointSplatSplat(device const SparkSplat *splats [[buffer(0)]],
                                device const uint *indices [[buffer(1)]],
                                device atomic_ulong *framebuffer [[buffer(2)]],
                                constant PointSplatUniforms &uniforms [[buffer(3)]],
                                device const uint *totals [[buffer(4)]],
                                device const ulong *framebufferRead [[buffer(5)]],
                                uint gid [[thread_position_in_grid]]) {
        // Dispatched over the full capacity; totals[0] is the actual point
        // count written by the workload distributor on the GPU timeline.
        if (gid >= min(totals[0], uniforms.capacity)) {
            return;
        }
        uint gaussianIndex = indices[gid];
        ProjectedGaussian projected = project(splats[gaussianIndex], uniforms);
        if (!projected.valid) {
            return;
        }

        GPSUInt2 seed = gps_make_seed(gid, uniforms.frameSeed * 2654435761u + 1u);
        GPSFloat2 u = gps_pcg2d(&seed);
        GPSFloat2 sample = gps_corrected_box_muller(u.x, u.y, projected.opacity);

        float2 pixel = floor(float2(projected.pixelMean.x + projected.c0 * sample.x,
                                    projected.pixelMean.y + projected.c1 * sample.x + projected.c2 * sample.y));
        int x = int(pixel.x);
        int y = int(pixel.y);
        if (x < 0 || x >= int(uniforms.drawableSize.x) || y < 0 || y >= int(uniforms.drawableSize.y)) {
            return;
        }

        // Rejection at the 3DGS truncation threshold: opacity * gaussian
        // weight below 1/255 never contributes in the reference rasterizer.
        float2 delta = projected.pixelMean - pixel;
        float gaussianWeight = exp(-0.5 * (projected.conic.x * delta.x * delta.x + 2.0 * projected.conic.y * delta.x * delta.y + projected.conic.z * delta.y * delta.y));
        if (projected.opacity * gaussianWeight < MIN_ALPHA) {
            return;
        }

        float4 rgba = float4(splats[gaussianIndex].color) / 255.0;
        ulong packed = (gps_pack_depth(projected.viewDepth, uniforms.nearPlane, uniforms.farPlane) << GPS_DEPTH_SHIFT)
            | gps_pack_color(rgba.r, rgba.g, rgba.b);

        uint index = uint(y) * uint(uniforms.drawableSize.x) + uint(x);
        // Early depth test avoids atomic contention for occluded points.
        // Metal's 64-bit atomics only support min/max (no load), so read
        // through a plain aliased view; a stale value only costs a
        // superfluous atomic_min, never correctness.
        if (framebufferRead[index] <= packed) {
            return;
        }
        atomic_min_explicit(&framebuffer[index], packed, memory_order_relaxed);
    }

    // Unpacks the 64-bit framebuffer into a color texture (1x1: no subpixel
    // averaging yet).
    kernel void pointSplatResolve(device const ulong *framebuffer [[buffer(0)]],
                                  constant PointSplatUniforms &uniforms [[buffer(1)]],
                                  texture2d<float, access::write> outTexture [[texture(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(uniforms.drawableSize.x) || gid.y >= uint(uniforms.drawableSize.y)) {
            return;
        }
        ulong value = framebuffer[gid.y * uint(uniforms.drawableSize.x) + gid.x];
        float3 color = float3(gps_unpack_channel(value, 24), gps_unpack_channel(value, 12), gps_unpack_channel(value, 0));
        outTexture.write(float4(color, 1.0), gid);
    }

} // namespace PointSplatRender
