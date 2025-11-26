import Foundation
import simd

// MARK: - Constants

/// Spherical harmonics coefficient C0 = 1 / (2 * sqrt(pi))
public let SH_C0: Float = 0.28209479177387814

// MARK: - Functions

/// Inverse log transform: sign(v) * (exp(abs(v)) - 1)
public func invLog(_ v: Float) -> Float {
    let a = abs(v)
    let e = exp(a) - 1.0
    return v < 0 ? -e : e
}

// MARK: - Extensions

public extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

public extension simd_float4 {
    var length: Scalar {
        simd_length(self)
    }
}

public extension SIMD4 where Scalar == Float {
    func clamped(to range: ClosedRange<Scalar>) -> Self {
        Self(
            x.clamped(to: range),
            y.clamped(to: range),
            z.clamped(to: range),
            w.clamped(to: range)
        )
    }
}

public extension simd_quatf {
    var vectorRealFirst: simd_float4 {
        [vector.w, vector.x, vector.y, vector.z]
    }
}
