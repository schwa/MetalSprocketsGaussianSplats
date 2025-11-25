#import <simd/simd.h>
#import "SparkSplatRenderShader.h"

// Helper structures and functions for Spark splat rendering

#ifdef __METAL_VERSION__
// Metal-only inline functions

#import <metal_stdlib>

namespace SparkSplatSupport {
    using namespace metal;

    // MARK: - Spherical Harmonics Constants

    constant float SH_C0 = 0.28209479177387814;
    constant float SH_C1 = 0.4886025119029199;
    constant float SH_C2_0 = 1.0925484305920792;
    constant float SH_C2_1 = 0.31539156525252005;
    constant float SH_C2_2 = 0.5462742152960396;
    constant float SH_C3_0 = 0.5900435899266435;
    constant float SH_C3_1 = 2.890611442640554;
    constant float SH_C3_2 = 0.4570457994644658;
    constant float SH_C3_3 = 0.3731763325901154;

    // MARK: - Spherical Harmonics Evaluation

    /// Evaluate spherical harmonics for view-dependent color
    /// coefficients layout: [coeff0_r, coeff0_g, coeff0_b, coeff1_r, ...]
    inline float3 evaluateSH(
        float3 viewDir,
        device const float* coefficients,
        uint splatIndex,
        uint shDegree
    ) {
        float3 result = float3(0.0);

        if (shDegree == 0 || coefficients == nullptr) {
            return result;
        }

        float x = viewDir.x;
        float y = viewDir.y;
        float z = viewDir.z;

        // Determine floats per splat based on degree
        uint floatsPerSplat = 0;
        if (shDegree == 1) floatsPerSplat = 9;      // 3 coeffs * 3 channels
        else if (shDegree == 2) floatsPerSplat = 24; // 8 coeffs * 3 channels
        else if (shDegree == 3) floatsPerSplat = 45; // 15 coeffs * 3 channels

        uint offset = splatIndex * floatsPerSplat;

        // Degree 1: 3 basis functions
        float basis1_0 = SH_C1 * y;
        float basis1_1 = SH_C1 * z;
        float basis1_2 = SH_C1 * x;

        result += basis1_0 * float3(coefficients[offset + 0], coefficients[offset + 1], coefficients[offset + 2]);
        result += basis1_1 * float3(coefficients[offset + 3], coefficients[offset + 4], coefficients[offset + 5]);
        result += basis1_2 * float3(coefficients[offset + 6], coefficients[offset + 7], coefficients[offset + 8]);

        if (shDegree < 2) return result;

        // Degree 2: 5 basis functions
        float xx = x * x, yy = y * y, zz = z * z;
        float xy = x * y, yz = y * z, xz = x * z;

        float basis2_0 = SH_C2_0 * xy;
        float basis2_1 = SH_C2_0 * yz;
        float basis2_2 = SH_C2_1 * (3.0 * zz - 1.0);
        float basis2_3 = SH_C2_0 * xz;
        float basis2_4 = SH_C2_2 * (xx - yy);

        result += basis2_0 * float3(coefficients[offset + 9], coefficients[offset + 10], coefficients[offset + 11]);
        result += basis2_1 * float3(coefficients[offset + 12], coefficients[offset + 13], coefficients[offset + 14]);
        result += basis2_2 * float3(coefficients[offset + 15], coefficients[offset + 16], coefficients[offset + 17]);
        result += basis2_3 * float3(coefficients[offset + 18], coefficients[offset + 19], coefficients[offset + 20]);
        result += basis2_4 * float3(coefficients[offset + 21], coefficients[offset + 22], coefficients[offset + 23]);

        if (shDegree < 3) return result;

        // Degree 3: 7 basis functions
        float basis3_0 = SH_C3_0 * y * (3.0 * xx - yy);
        float basis3_1 = SH_C3_1 * xy * z;
        float basis3_2 = SH_C3_2 * y * (5.0 * zz - 1.0);
        float basis3_3 = SH_C3_3 * z * (5.0 * zz - 3.0);
        float basis3_4 = SH_C3_2 * x * (5.0 * zz - 1.0);
        float basis3_5 = SH_C3_1 * z * (xx - yy);
        float basis3_6 = SH_C3_0 * x * (xx - 3.0 * yy);

        result += basis3_0 * float3(coefficients[offset + 24], coefficients[offset + 25], coefficients[offset + 26]);
        result += basis3_1 * float3(coefficients[offset + 27], coefficients[offset + 28], coefficients[offset + 29]);
        result += basis3_2 * float3(coefficients[offset + 30], coefficients[offset + 31], coefficients[offset + 32]);
        result += basis3_3 * float3(coefficients[offset + 33], coefficients[offset + 34], coefficients[offset + 35]);
        result += basis3_4 * float3(coefficients[offset + 36], coefficients[offset + 37], coefficients[offset + 38]);
        result += basis3_5 * float3(coefficients[offset + 39], coefficients[offset + 40], coefficients[offset + 41]);
        result += basis3_6 * float3(coefficients[offset + 42], coefficients[offset + 43], coefficients[offset + 44]);

        return result;
    }

    // MARK: - Quaternion Math

    /// Rotate vector by quaternion
    inline float3 quatVec(float4 q, float3 v) {
        float3 t = 2.0 * cross(q.xyz, v);
        return v + q.w * t + cross(q.xyz, t);
    }

    /// Multiply two quaternions
    inline float4 quatQuat(float4 q1, float4 q2) {
        return float4(
            q1.w * q2.x + q1.x * q2.w + q1.y * q2.z - q1.z * q2.y,
            q1.w * q2.y - q1.x * q2.z + q1.y * q2.w + q1.z * q2.x,
            q1.w * q2.z + q1.x * q2.y - q1.y * q2.x + q1.z * q2.w,
            q1.w * q2.w - q1.x * q2.x - q1.y * q2.y - q1.z * q2.z
        );
    }

    /// Build rotation-scale matrix from scale vector and quaternion
    inline float3x3 scaleQuaternionToMatrix(float3 s, float4 q) {
        return float3x3(
            s.x * (1.0 - 2.0 * (q.y * q.y + q.z * q.z)),
            s.x * (2.0 * (q.x * q.y + q.w * q.z)),
            s.x * (2.0 * (q.x * q.z - q.w * q.y)),

            s.y * (2.0 * (q.x * q.y - q.w * q.z)),
            s.y * (1.0 - 2.0 * (q.x * q.x + q.z * q.z)),
            s.y * (2.0 * (q.y * q.z + q.w * q.x)),

            s.z * (2.0 * (q.x * q.z + q.w * q.y)),
            s.z * (2.0 * (q.y * q.z - q.w * q.x)),
            s.z * (1.0 - 2.0 * (q.x * q.x + q.y * q.y))
        );
    }

    // MARK: - Projection Math Structures

    /// Result of 2D eigendecomposition for ellipse parameters
    struct Eigen2D {
        float2 majorAxis;      // Major axis direction scaled by sqrt(eigenvalue) * maxStdDev
        float2 minorAxis;      // Minor axis direction scaled by sqrt(eigenvalue) * maxStdDev
        float lambda1;         // Larger eigenvalue
        float lambda2;         // Smaller eigenvalue
    };

    /// Result of 2D covariance computation
    struct Covariance2D {
        float a;    // cov[0][0] - variance in x
        float b;    // cov[0][1] = cov[1][0] - covariance
        float d;    // cov[1][1] - variance in y
    };

    // MARK: - Covariance

    /// Compute 3D covariance matrix from rotation-scale matrix
    /// Covariance = RS * RS^T
    inline float3x3 compute3DCovariance(float3x3 rotationScale) {
        return rotationScale * transpose(rotationScale);
    }

    // MARK: - Projection Jacobian

    /// Compute Jacobian of perspective projection at a view-space position
    inline float3x3 computeProjectionJacobian(float3 viewPosition, float2 focal) {
        float invZ = 1.0 / viewPosition.z;
        float2 J1 = focal * invZ;
        float2 J2 = -(J1 * viewPosition.xy) * invZ;

        return float3x3(
            float3(J1.x, 0.0, J2.x),
            float3(0.0, J1.y, J2.y),
            float3(0.0, 0.0, 0.0)
        );
    }

    // MARK: - 2D Covariance Projection

    /// Project 3D covariance to 2D using the Jacobian
    /// cov2D = J^T * cov3D * J
    inline Covariance2D projectCovarianceTo2D(float3x3 cov3D, float3x3 jacobian) {
        float3x3 cov2D = transpose(jacobian) * cov3D * jacobian;
        return Covariance2D {
            .a = cov2D[0][0],
            .b = cov2D[0][1],
            .d = cov2D[1][1]
        };
    }

    // MARK: - Eigendecomposition

    /// Compute eigendecomposition of 2D covariance for splat ellipse
    inline Eigen2D eigendecompose2D(Covariance2D cov2D, float maxPixelRadius, float maxStdDev) {
        float a = cov2D.a;
        float b = cov2D.b;
        float d = cov2D.d;
        float det = a * d - b * b;

        // Eigenvalue computation using the characteristic equation
        float eigenAvg = 0.5 * (a + d);
        float eigenDelta = sqrt(max(0.0, eigenAvg * eigenAvg - det));
        float eigen1 = eigenAvg + eigenDelta;
        float eigen2 = eigenAvg - eigenDelta;

        // Compute eigenvector for larger eigenvalue
        float2 eigenVec1 = normalize(float2((abs(b) < 0.001) ? 1.0 : b, eigen1 - a));
        float2 eigenVec2 = float2(eigenVec1.y, -eigenVec1.x);

        // Compute scales in pixels (clamped to max radius)
        float scale1 = min(maxPixelRadius, maxStdDev * sqrt(eigen1));
        float scale2 = min(maxPixelRadius, maxStdDev * sqrt(eigen2));

        return Eigen2D {
            .majorAxis = eigenVec1 * scale1,
            .minorAxis = eigenVec2 * scale2,
            .lambda1 = eigen1,
            .lambda2 = eigen2
        };
    }

    // MARK: - Quad Vertex Computation

    /// Compute the vertex position for a splat quad
    inline float4 computeSplatQuadVertex(
        float2 quadPosition,
        float3 ndcCenter,
        Eigen2D eigen,
        float2 drawableSize,
        float clipW
    ) {
        float2 pixelOffset = quadPosition.x * eigen.majorAxis + quadPosition.y * eigen.minorAxis;
        float2 ndcOffset = (2.0 / drawableSize) * pixelOffset;
        float3 ndc = float3(ndcCenter.xy + ndcOffset, ndcCenter.z);

        return float4(ndc.xy * clipW, ndcCenter.z * clipW, clipW);
    }

    // MARK: - Helper Functions

    /// Compute focal length from projection matrix and drawable size
    inline float2 computeFocalLength(float4x4 projectionMatrix, float2 drawableSize) {
        return 0.5 * drawableSize * float2(projectionMatrix[0][0], projectionMatrix[1][1]);
    }

    /// Extract 3x3 rotation matrix from 4x4 transform matrix
    inline float3x3 extractRotation3x3(float4x4 matrix) {
        return float3x3(
            matrix[0].xyz,
            matrix[1].xyz,
            matrix[2].xyz
        );
    }

    /// Transform rotation-scale matrix from model space to view space
    inline float3x3 transformToViewSpace(float4x4 modelMatrix, float4x4 viewMatrix, float3x3 localRS) {
        float3x3 viewRotation = extractRotation3x3(viewMatrix);
        float3x3 modelRotation = extractRotation3x3(modelMatrix);
        return viewRotation * modelRotation * localRS;
    }

}

#endif // __METAL_VERSION__
