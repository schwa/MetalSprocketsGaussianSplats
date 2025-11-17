#if os(iOS) || (os(macOS) && !arch(x86_64))
import simd
import MetalSprocketsSupport
import GeometryLite3D

public extension Antimatter15Splat {
    init(_ splat: SPZSplat) {
        let position = Packed3<Float>(splat.position)

        let actualScale = SIMD3<Float>(
            exp(splat.scale.x),
            exp(splat.scale.y),
            exp(splat.scale.z)
        )
        let scale = Packed3<Float>(actualScale)

        let normalizedColor = splat.color * 0.15 + 0.5
        let rgb = normalizedColor.clamped(to: 0...1) * 255
        let alphaU8 = UInt8((1.0 / (1.0 + exp(-splat.alpha))).clamped(to: 0...1) * 255)
        let color = SIMD4<UInt8>(UInt8(rgb.x), UInt8(rgb.y), UInt8(rgb.z), alphaU8)

        let rotation_vector = splat.rotation.vectorRealFirst
        let rotation = ((rotation_vector / rotation_vector.length) * 128 + 128).clamped(to: 0...255)

        self = Antimatter15Splat(
            position: position,
            scale: scale,
            color: color,
            rotation: SIMD4<UInt8>(rotation)
        )
    }
}

extension SIMD3 where Scalar == Float {
    func clamped(to range: ClosedRange<Scalar>) -> Self {
        Self(map { $0.clamped(to: range) })
    }
}
#endif
