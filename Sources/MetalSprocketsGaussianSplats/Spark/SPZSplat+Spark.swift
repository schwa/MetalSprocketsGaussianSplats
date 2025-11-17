#if os(iOS) || (os(macOS) && !arch(x86_64))
import simd

public extension SparkGPUSplat {
    /// Initialize a SparkGPUSplat from an Antimatter15Splat (.splat file format)
    init(_ splat: Antimatter15Splat) {
        // Position: direct copy
        let position = SIMD3<Float>(splat.position)

        // Scale: already in actual scale (not log)
        let scale = SIMD3<Float>(splat.scale)

        // Color: already in 0-255 range
        let color = splat.color

        // Rotation: convert from UInt8 encoding to quaternion
        // .splat format stores as (value - 128) / 128 mapping to [-1, 1]
        let rot = SIMD4<Float>(
            (Float(splat.rotation.x) - 128.0) / 128.0,
            (Float(splat.rotation.y) - 128.0) / 128.0,
            (Float(splat.rotation.z) - 128.0) / 128.0,
            (Float(splat.rotation.w) - 128.0) / 128.0
        )
        // .splat format uses wxyz order, simd_quatf uses xyzw (imag first, real last)
        let quaternion = simd_normalize(simd_quatf(ix: rot.y, iy: rot.z, iz: rot.w, r: rot.x))

        self.init(
            position: position,
            scale: scale,
            quaternion: quaternion,
            color: color
        )
    }

    /// Initialize a SparkGPUSplat from an SPZSplat
    init(_ splat: SPZSplat) {
        // Convert position directly (SPZ uses RUB coordinate system)
        let position = splat.position

        // Convert scale from log space (SPZ stores log scale)
        let actualScale = SIMD3<Float>(
            exp(splat.scale.x),
            exp(splat.scale.y),
            exp(splat.scale.z)
        )

        // Convert color from SH coefficient space to linear RGB [0,1]
        // SPZ stores: (value - 0.5) / 0.15, so we reverse: value = splat.color * 0.15 + 0.5
        let normalizedColor = splat.color * 0.15 + 0.5
        let rgb = normalizedColor.clamped(to: 0...1) * 255

        // Convert alpha from logit space to probability using sigmoid
        let alphaProbability = 1.0 / (1.0 + exp(-splat.alpha))
        let alphaU8 = UInt8(alphaProbability.clamped(to: 0...1) * 255)

        let color = SIMD4<UInt8>(
            UInt8(rgb.x),
            UInt8(rgb.y),
            UInt8(rgb.z),
            alphaU8
        )

        // Rotation quaternion - ensure it's normalized
        let rotation = simd_normalize(splat.rotation)

        self.init(
            position: position,
            scale: actualScale,
            quaternion: rotation,
            color: color
        )
    }

    /// Initialize a SparkGPUSplat from a PLY record
    init?(plyRecord record: PLYReader.Record) {
        // Extract position
        guard let x = record["x"]?.floatValue,
              let y = record["y"]?.floatValue,
              let z = record["z"]?.floatValue else {
            return nil
        }
        let position = SIMD3<Float>(x, y, z)

        // Extract scale (stored as log scale in PLY)
        guard let sx = record["scale_0"]?.floatValue,
              let sy = record["scale_1"]?.floatValue,
              let sz = record["scale_2"]?.floatValue else {
            return nil
        }
        let scale = SIMD3<Float>(exp(sx), exp(sy), exp(sz))

        // Extract rotation quaternion (wxyz order in PLY)
        guard let rw = record["rot_0"]?.floatValue,
              let rx = record["rot_1"]?.floatValue,
              let ry = record["rot_2"]?.floatValue,
              let rz = record["rot_3"]?.floatValue else {
            return nil
        }
        let quaternion = simd_normalize(simd_quatf(ix: rx, iy: ry, iz: rz, r: rw))

        // Extract color from spherical harmonics DC term
        // SH DC coefficient: color = (f_dc * SH_C0 + 0.5), where SH_C0 = 0.28209479177387814
        let SH_C0: Float = 0.28209479177387814
        guard let f_dc_0 = record["f_dc_0"]?.floatValue,
              let f_dc_1 = record["f_dc_1"]?.floatValue,
              let f_dc_2 = record["f_dc_2"]?.floatValue else {
            return nil
        }
        let r = (f_dc_0 * SH_C0 + 0.5).clamped(to: 0...1) * 255
        let g = (f_dc_1 * SH_C0 + 0.5).clamped(to: 0...1) * 255
        let b = (f_dc_2 * SH_C0 + 0.5).clamped(to: 0...1) * 255

        // Extract opacity (stored as logit in PLY, convert via sigmoid)
        guard let opacity = record["opacity"]?.floatValue else {
            return nil
        }
        let alpha = 1.0 / (1.0 + exp(-opacity))
        let alphaU8 = UInt8(alpha.clamped(to: 0...1) * 255)

        let color = SIMD4<UInt8>(UInt8(r), UInt8(g), UInt8(b), alphaU8)

        self.init(
            position: position,
            scale: scale,
            quaternion: quaternion,
            color: color
        )
    }
}

// MARK: - Helper Extensions

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif
