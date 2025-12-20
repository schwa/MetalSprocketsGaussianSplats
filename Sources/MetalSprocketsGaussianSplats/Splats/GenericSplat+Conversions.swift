#if !arch(x86_64)
import GeometryLite3D
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

public extension Antimatter15Splat {
    /// Initialize an Antimatter15Splat from a GenericSplat
    init(_ splat: GenericSplat) {
        let position = Packed3<Float>(splat.position)
        let scale = Packed3<Float>(splat.scale)
        let color = SIMD4<UInt8>(splat.color.clamped(to: 0...1) * 255)
        // rotation is stored as (x, y, z, w), convert to (w, x, y, z) for encoding
        let rotation_vector = SIMD4<Float>(splat.rotation.w, splat.rotation.x, splat.rotation.y, splat.rotation.z)
        let rotation = ((rotation_vector / simd_length(rotation_vector)) * 128.0 + 128.0).clamped(to: 0...255)
        self = Antimatter15Splat(position: position, scale: scale, color: color, rotation: SIMD4<UInt8>(rotation))
    }
}

public extension SparkSplat {
    /// Initialize a SparkSplat from a GenericSplat
    init(_ splat: GenericSplat) {
        self.init()
        self.position = simd_half3(splat.position)
        self.scale = simd_half3(splat.scale)
        self.rotation = simd_half4(splat.rotation)
        self.color = SIMD4<UInt8>(splat.color.clamped(to: 0...1) * 255.0)
    }
}

public extension Antimatter15GPUSplat {
    /// Initialize an Antimatter15GPUSplat from a GenericSplat
    init(_ splat: GenericSplat) {
        // Extract position
        let position = splat.position

        // Copy color components directly (convert 0-1 to 0-255)
        let color = SIMD4<UInt8>(splat.color.clamped(to: 0...1) * 255.0)

        // Extract scale
        let scale = splat.scale

        // rotation is already in [-1, 1] range as simd_float4
        let rot: [Float] = [splat.rotation.x, splat.rotation.y, splat.rotation.z, splat.rotation.w]

        // Calculate individual matrix elements (flattened)
        let m = [
            1.0 - 2.0 * (rot[2] * rot[2] + rot[3] * rot[3]),
            2.0 * (rot[1] * rot[2] + rot[0] * rot[3]),
            2.0 * (rot[1] * rot[3] - rot[0] * rot[2]),

            2.0 * (rot[1] * rot[2] - rot[0] * rot[3]),
            1.0 - 2.0 * (rot[1] * rot[1] + rot[3] * rot[3]),
            2.0 * (rot[2] * rot[3] + rot[0] * rot[1]),

            2.0 * (rot[1] * rot[3] + rot[0] * rot[2]),
            2.0 * (rot[2] * rot[3] - rot[0] * rot[1]),
            1.0 - 2.0 * (rot[1] * rot[1] + rot[2] * rot[2])
        ].enumerated().map { $0.element * scale[$0.offset / 3] }

        // Compute sigma values
        var sigma = [
            m[0] * m[0] + m[3] * m[3] + m[6] * m[6],
            m[0] * m[1] + m[3] * m[4] + m[6] * m[7],
            m[0] * m[2] + m[3] * m[5] + m[6] * m[8],
            m[1] * m[1] + m[4] * m[4] + m[7] * m[7],
            m[1] * m[2] + m[4] * m[5] + m[7] * m[8],
            m[2] * m[2] + m[5] * m[5] + m[8] * m[8]
        ]

        sigma = sigma.map { $0 * 4 }

        // Convert sigma values into simd_half2 pairs
        let u1 = simd_half2(Float16(sigma[0]), Float16(sigma[1]))
        let u2 = simd_half2(Float16(sigma[2]), Float16(sigma[3]))
        let u3 = simd_half2(Float16(sigma[4]), Float16(sigma[5]))

        // Construct and return the Antimatter15GPUSplat
        self = Antimatter15GPUSplat(
            position: SIMD3<Float>(position),
            u1: u1,
            u2: u2,
            u3: u3,
            color: color
        )
    }
}
#endif
