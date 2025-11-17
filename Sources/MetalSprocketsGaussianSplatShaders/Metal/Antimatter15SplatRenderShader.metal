#import "GaussianSplatShaders.h"
#import "Antimatter15SplatSupport.h"

#import <metal_logging>
#import <metal_stdlib>
#import <metal_uniform>

using namespace metal;
using namespace Antimatter15SplatSupport;

namespace Antimatter15SplatRenderShader {

    constant int debug_mode [[function_constant(2)]];

    struct VertexIn {
        float3 position [[attribute(0)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 relativePosition;
        float4 color;
    };

    typedef VertexOut FragmentIn;

    // MARK: -

    [[vertex]] VertexOut vertex_main(
        VertexIn in [[stage_in]],
        uint instance_id [[instance_id]],
        uint vertex_id [[vertex_id]],
        constant GPUSplat *splats [[buffer(2)]],
        constant IndexedDistance *indexedDistances [[buffer(3)]],
        constant float4x4 &modelMatrix [[buffer(4)]],
        constant float4x4 &viewMatrix [[buffer(5)]],
        constant float4x4 &projectionMatrix [[buffer(6)]],
        constant float2 &drawableSize [[buffer(8)]],
        constant float &scale [[buffer(9)]]
    ) {
        VertexOut out;
        const uint splatIndex = indexedDistances[instance_id].index;
        const GPUSplat splat = splats[splatIndex];
        if (vertex_id == 0 && instance_id == 0) {
            os_log_default.log(
                "splat #%d. [%f, %f, %f] [%f, %f] [%f, %f] [%f, %f]", splatIndex, splat.position.x, splat.position.y,
                splat.position.z, splat.u1.x, splat.u1.y, splat.u2.x, splat.u2.y, splat.u3.x, splat.u3.y
            );
        }
        const float2 focal = float2(projectionMatrix[1][1], projectionMatrix[2][2]) * drawableSize / 2;
        const float4x4 modelViewMatrix = viewMatrix * modelMatrix;
        const float4 cam = modelViewMatrix * float4(splat.position, 1);
        float4 pos2d = projectionMatrix * cam;

        const float clip = 1.2 * pos2d.w;
        if (pos2d.z < -clip || pos2d.x < -clip || pos2d.x > clip || pos2d.y < -clip || pos2d.y > clip) {
            out.position = float4(0.0, 0.0, 2.0, 1.0);
            return out;
        }

        // Compute covariance and axes using shared function
        const CovarianceResult cov = computeCovariance(
            float2(splat.u1),
            float2(splat.u2),
            float2(splat.u3),
            cam,
            focal,
            modelViewMatrix
        );

        if (instance_id == 0) {
            os_log_default.log(
                "#%d - lambda1: %f, lambda2: %f", vertex_id, cov.lambda1, cov.lambda2
            );
        }

        if (!cov.valid) {
            out.position = float4(0.0, 0.0, 2.0, 1.0);
            return out;
        }

        if (instance_id == 0) {
            os_log_default.log(
                "#%d - majorAxis: %f, %f, minorAxis: %f, %f", vertex_id, cov.majorAxis.x, cov.majorAxis.y, cov.minorAxis.x,
                cov.minorAxis.y
            );
        }

        out.color = clamp(pos2d.z / pos2d.w + 1.0, 0.0, 1.0) * float4(splat.color) / 255.0;

        if (instance_id == 0) {
            const float3 vertexPosition = in.position * 2.0;
            os_log_default.log(
                "#%d - scale: %f, vertexPosition: %f, %f, %f", vertex_id, scale, vertexPosition.x, vertexPosition.y,
                vertexPosition.z
            );
        }

        const QuadVertex quadVertex = computeQuadVertex(in.position, pos2d, cov.majorAxis, cov.minorAxis, drawableSize, scale);
        out.position = quadVertex.position;
        out.relativePosition = quadVertex.relativePosition;

        if (instance_id == 0) {
            os_log_default.log(
                "OUT: %d [%f, %f, %f, %f]", vertex_id, out.position.x, out.position.y, out.position.z, out.position.w
            );
        }

        return out;
    }

    // MARK: -

    [[fragment]] float4 fragment_main(FragmentIn in [[stage_in]], uint primitive_id [[primitive_id]]) {
        if (debug_mode == 1) {
            switch (primitive_id) {
            case 0:
                return float4(1, 0, 0, 1);
            case 1:
                return float4(0, 1, 0, 1);
            default:
                return float4(0, 0, 0, 0);
            }
        } else if (debug_mode == 2) {
            return float4(in.color.rgb, 1);
        } else {
            float A = -dot(in.relativePosition, in.relativePosition);
            if (A < -4.0) {
                discard_fragment();
            }
            float B = exp(A) * in.color.a;
            return float4(B * in.color.rgb, B);
        }
    }


}; // namespace Antimatter15SplatRenderShader
