#import <simd/simd.h>

// Helper structures for Gaussian Splat rendering

struct QuadVertex {
    simd_float4 position;
    simd_float2 relativePosition;
};

struct BoundingBox {
    simd_float2 min;
    simd_float2 max;
};

#ifdef __METAL_VERSION__
// Metal-only inline functions

#import <metal_stdlib>

namespace GaussianSplatSupport {
    using namespace metal;

    struct CovarianceResult {
        float2 majorAxis;
        float2 minorAxis;
        float lambda1;
        float lambda2;
        bool valid;
    };

    inline float3x3 truncateTo3x3(const float4x4 M) {
        return float3x3(M[0].xyz, M[1].xyz, M[2].xyz);
    }

    inline CovarianceResult computeCovariance(
        float2 u1,
        float2 u2,
        float2 u3,
        float4 cam,
        float2 focal,
        float4x4 modelViewMatrix
    ) {
        CovarianceResult result;
        result.valid = true;

        // Construct covariance matrix in 3D
        const float3x3 Vrk = float3x3(u1.x, u1.y, u2.x, u1.y, u2.y, u3.x, u2.x, u3.x, u3.y);

        // Jacobian of perspective projection
        const float3x3 J = float3x3(
            focal.x / cam.z, 0, -(focal.x * cam.x) / (cam.z * cam.z),
            0, -focal.y / cam.z, (focal.y * cam.y) / (cam.z * cam.z),
            0, 0, 0
        );

        // Project covariance to 2D
        const float3x3 T = transpose(truncateTo3x3(modelViewMatrix)) * J;
        const float3x3 cov2d = transpose(T) * Vrk * T;

        // Compute eigenvalues
        const float mid = (cov2d[0][0] + cov2d[1][1]) / 2.0;
        const float radius = length(float2((cov2d[0][0] - cov2d[1][1]) / 2.0, cov2d[0][1]));
        const float lambda1 = mid + radius;
        const float lambda2 = mid - radius;

        result.lambda1 = lambda1;
        result.lambda2 = lambda2;

        if (lambda2 < 0.0) {
            result.valid = false;
            return result;
        }

        // Compute eigenvectors (major and minor axes)
        float2 diagonalVector = normalize(float2(cov2d[0][1], lambda1 - cov2d[0][0]));
        if (any(isnan(diagonalVector))) {
            diagonalVector = float2(1.0, 0.0);
        }

        result.majorAxis = min(sqrt(2.0 * lambda1), 1024.0) * diagonalVector;
        result.minorAxis = min(sqrt(2.0 * lambda2), 1024.0) * float2(diagonalVector.y, -diagonalVector.x);

        return result;
    }

    inline QuadVertex computeQuadVertex(
        float3 inputPosition,
        float4 pos2d,
        float2 majorAxis,
        float2 minorAxis,
        float2 drawableSize,
        float scale
    ) {
        QuadVertex result;

        const float2 vCenter = pos2d.xy / pos2d.w;
        const float3 vertexPosition = inputPosition * 2.0;

        const float2 position =
            vertexPosition.x * majorAxis / drawableSize + vertexPosition.y * minorAxis / drawableSize;
        result.relativePosition = inputPosition.xy * scale;

        result.position = float4(vCenter + position, 0.0, 1.0);

        return result;
    }

    inline BoundingBox computeSplatBoundingBox(
        float4 pos2d,
        float2 majorAxis,
        float2 minorAxis,
        float2 drawableSize,
        float scale
    ) {
        // Compute the 4 corners of the quad (must match vertex positions in rendering)
        const float3 corners[4] = {
            float3(-1.0, -1.0, 0.0),
            float3( 1.0, -1.0, 0.0),
            float3( 1.0,  1.0, 0.0),
            float3(-1.0,  1.0, 0.0)
        };

        BoundingBox bounds;
        bounds.min = float2(INFINITY, INFINITY);
        bounds.max = float2(-INFINITY, -INFINITY);

        for (int i = 0; i < 4; i++) {
            QuadVertex v = computeQuadVertex(corners[i], pos2d, majorAxis, minorAxis, drawableSize, scale);
            bounds.min = min(bounds.min, v.position.xy);
            bounds.max = max(bounds.max, v.position.xy);
        }

        return bounds;
    }
}

#endif // __METAL_VERSION__
