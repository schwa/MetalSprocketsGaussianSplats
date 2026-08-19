#if !arch(x86_64)
import GeometryLite3D
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

public extension SparkSplat {
    /// Creates a SparkSplat from a GenericSplat. Color is clamped to 0...1 and scaled to 0...255.
    init(_ splat: GenericSplat) {
        self.init()
        self.position = simd_half3(splat.position)
        self.scale = simd_half3(splat.scale)
        self.rotation = simd_half4(splat.rotation)
        self.color = SIMD4<UInt8>(splat.color.clamped(to: 0...1) * 255.0)
    }
}
#endif
