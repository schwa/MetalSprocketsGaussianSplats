#if !arch(x86_64)
import MetalSprocketsGaussianSplatShaders
import simd

// SparkSplat comes from a C header (32 bytes):
//   simd_half3 position
//   simd_half3 scale
//   simd_half4 rotation
//   simd_uchar4 color

extension SparkSplat: @unchecked @retroactive Sendable {
}

extension SparkSplat: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.position == rhs.position &&
            lhs.scale == rhs.scale &&
            lhs.rotation == rhs.rotation &&
            lhs.color == rhs.color
    }
}

extension SparkSplat: SortableSplatProtocol {
    public var floatPosition: SIMD3<Float> {
        SIMD3<Float>(position)
    }
}
#endif
