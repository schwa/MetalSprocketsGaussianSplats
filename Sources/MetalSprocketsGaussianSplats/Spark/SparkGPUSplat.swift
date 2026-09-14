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

public extension SparkSplat {
    /// Convenience initializer that defaults `shIndex` to 0 (identity is set by
    /// the cloud builders). Keeps call sites that predate the SH-index field.
    init(position: simd_half3, scale: simd_half3, rotation: simd_half4, color: simd_uchar4) {
        self.init(position: position, scale: scale, rotation: rotation, color: color, shIndex: 0)
    }
}
#endif
