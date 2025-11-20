#if os(iOS) || (os(macOS) && !arch(x86_64))
import MetalSprocketsGaussianSplatShaders
import simd

public extension SparkGPUSplat {
    /// Initialize a SparkGPUSplat from a GenericSplat
    init(_ splat: GenericSplat) {
        // Position: direct copy
        let position = splat.position

        // Scale: direct copy (GenericSplat already has actual scale, not log)
        let scale = splat.scale

        // Color: convert from [0,1] float to [0,255] UInt8
        let color = SIMD4<UInt8>(
            UInt8(splat.color.x.clamped(to: 0...1) * 255),
            UInt8(splat.color.y.clamped(to: 0...1) * 255),
            UInt8(splat.color.z.clamped(to: 0...1) * 255),
            UInt8(splat.color.w.clamped(to: 0...1) * 255)
        )

        // Rotation: normalize quaternion
        let quaternion = simd_normalize(splat.rotation)

        self.init(
            position: position,
            scale: scale,
            quaternion: quaternion,
            color: color
        )
    }
}

public extension Antimatter15GPUSplat {
    /// Initialize an Antimatter15GPUSplat from a GenericSplat
    init(_ splat: GenericSplat) {
        // Convert via Antimatter15Splat
        let am15 = Antimatter15Splat(splat)
        self.init(am15)
    }
}

// MARK: - Helper Extensions

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif
