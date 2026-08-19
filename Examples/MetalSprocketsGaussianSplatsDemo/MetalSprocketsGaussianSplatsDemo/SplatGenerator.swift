#if !arch(x86_64)
import MetalSprocketsGaussianSplatShaders
import simd

/// Procedural sphere-rainbow splat generator. A port of
/// `gen-sphere-rainbow.mjs` from splat-transform. It places uniform points in
/// a sphere, maps hue to height, and adds a subtle lat/long checkerboard.
enum SplatGenerator {
    /// Preset counts that match the pre-generated sphere-NN.sog test files.
    static let presetCounts: [Int] = [
        100_000, 500_000, 1_000_000, 2_000_000, 4_000_000,
        8_000_000, 16_000_000, 32_000_000, 48_000_000
    ]

    static func label(for count: Int) -> String {
        count >= 1_000_000 ? "\(count / 1_000_000)M" : "\(count / 1_000)K"
    }

    static func generate(count: Int, radius: Float = 0.5, seed: UInt32 = 12_345) -> [SparkSplat] {
        // Deterministic PRNG (mulberry32), identical to the .mjs script.
        func rand(_ i: UInt32) -> Float {
            var t = seed &+ i &* 0x6D2B_79F5
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ (t ^ (t >> 7)) &* (t | 61)
            return Float(t ^ (t >> 14)) / 4_294_967_296
        }

        func hueToRGB(_ h: Float) -> SIMD3<Float> {
            func f(_ n: Float) -> Float {
                let k = (n + h * 6).truncatingRemainder(dividingBy: 6)
                return 1 - max(0, min(k, 4 - k, 1))
            }
            return SIMD3<Float>(f(5), f(3), f(1))
        }

        var splats: [SparkSplat] = []
        splats.reserveCapacity(count)
        for index in 0..<count {
            let base = UInt32(truncatingIfNeeded: index) &* 16
            func r(_ k: UInt32) -> Float {
                rand(base &+ k)
            }

            // Uniform point in a sphere: random direction, radius ~ u^(1/3).
            let cosTheta = 2 * r(0) - 1
            let sinTheta = (1 - cosTheta * cosTheta).squareRoot()
            let phi = 2 * Float.pi * r(1)
            let rad = radius * cbrt(r(2))

            let position = SIMD3<Float>(
                rad * sinTheta * cos(phi),
                rad * cosTheta,
                rad * sinTheta * sin(phi)
            )

            // Splat size proportional to sphere radius (linear scale). The
            // script stores log-scale, which the PLY reader would exp().
            let s = (0.002 + r(3) * 0.004) * radius

            // Rainbow: hue from bottom (red) to top (violet), with a subtle
            // checkerboard from lat/long cells of the direction from center.
            var color = hueToRGB(((position.y / radius) + 1) * 0.5 * 0.83)
            let lat = acos(cosTheta) / .pi
            let lon = phi / (2 * .pi)
            let checker = (Int(lat * 12) + Int(lon * 24)) % 2
            color *= checker == 1 ? 1.0 : 0.85

            // Random rotation (Shoemake); w, x, y, z per 3DGS convention.
            let u1 = r(4)
            let u2 = r(5)
            let u3 = r(6)
            let a = (1 - u1).squareRoot()
            let b = u1.squareRoot()
            // The script emits rot_0..3 = (w, x, y, z). SparkSplat stores (x, y, z, w).
            let rotation = SIMD4<Float>(
                a * cos(2 * .pi * u2),
                b * sin(2 * .pi * u3),
                b * cos(2 * .pi * u3),
                a * sin(2 * .pi * u2)
            )

            var splat = SparkSplat()
            splat.position = simd_half3(position)
            splat.scale = simd_half3(SIMD3<Float>(repeating: s))
            splat.rotation = simd_half4(rotation)
            splat.color = SIMD4<UInt8>(simd_clamp(SIMD4<Float>(color, 0.8), .zero, .one) * 255.0)
            splats.append(splat)
        }
        return splats
    }
}
#endif
