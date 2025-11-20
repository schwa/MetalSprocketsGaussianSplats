#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import GeometryLite3D
import MetalSprocketsSupport
import simd

public extension Antimatter15Splat {
    /// Initializes an Antimatter15Splat from a PLY record
    /// Supports standard Gaussian Splat PLY format with properties:
    /// - Position: x, y, z
    /// - Scale: scale_0, scale_1, scale_2
    /// - Color: f_dc_0, f_dc_1, f_dc_2 or red, green, blue
    /// - Rotation: rot_0, rot_1, rot_2, rot_3 (quaternion)
    /// - Opacity: opacity
    init?(plyRecord record: PLYReader.Record) {
        // Extract position (required)
        guard let x = record["x"]?.floatValue, let y = record["y"]?.floatValue, let z = record["z"]?.floatValue else {
            return nil
        }

        // Extract scale - try scale_0/1/2 first, fall back to sx/sy/sz
        let scaleX = record["scale_0"]?.floatValue ?? record["sx"]?.floatValue ?? 0.0
        let scaleY = record["scale_1"]?.floatValue ?? record["sy"]?.floatValue ?? 0.0
        let scaleZ = record["scale_2"]?.floatValue ?? record["sz"]?.floatValue ?? 0.0

        // Extract color - try f_dc_0/1/2 (Gaussian splat format), fall back to red/green/blue
        let colorR: Float
        let colorG: Float
        let colorB: Float

        if let fdc0 = record["f_dc_0"]?.floatValue, let fdc1 = record["f_dc_1"]?.floatValue, let fdc2 = record["f_dc_2"]?.floatValue {
            // Convert from spherical harmonics DC coefficient to color
            // SH C0 coefficient: 0.28209479177387814
            let SH_C0: Float = 0.28209479177387814
            colorR = (fdc0 * SH_C0 + 0.5).clamped(to: 0...1)
            colorG = (fdc1 * SH_C0 + 0.5).clamped(to: 0...1)
            colorB = (fdc2 * SH_C0 + 0.5).clamped(to: 0...1)
        } else if let red = record["red"]?.floatValue, let green = record["green"]?.floatValue, let blue = record["blue"]?.floatValue {
            // Normalize if values are in 0-255 range
            if red > 1.0 || green > 1.0 || blue > 1.0 {
                colorR = (red / 255.0).clamped(to: 0...1)
                colorG = (green / 255.0).clamped(to: 0...1)
                colorB = (blue / 255.0).clamped(to: 0...1)
            } else {
                colorR = red.clamped(to: 0...1)
                colorG = green.clamped(to: 0...1)
                colorB = blue.clamped(to: 0...1)
            }
        } else {
            // Default to white if no color found
            colorR = 1.0
            colorG = 1.0
            colorB = 1.0
        }

        // Extract opacity/alpha
        let opacity = (record["opacity"]?.floatValue ?? record["alpha"]?.floatValue ?? 1.0).clamped(to: 0...1)

        // Extract rotation - quaternion (x, y, z, w)
        let rotX = record["rot_0"]?.floatValue ?? 0.0
        let rotY = record["rot_1"]?.floatValue ?? 0.0
        let rotZ = record["rot_2"]?.floatValue ?? 0.0
        let rotW = record["rot_3"]?.floatValue ?? 1.0

        // Normalize quaternion
        let quat = simd_quatf(ix: rotX, iy: rotY, iz: rotZ, r: rotW).normalized

        // Convert to Antimatter15Splat format
        let position = Packed3<Float>(SIMD3<Float>(x, y, z))
        let scale = Packed3<Float>(SIMD3<Float>(exp(scaleX), exp(scaleY), exp(scaleZ)))
        let color = SIMD4<UInt8>(
            UInt8(colorR * 255),
            UInt8(colorG * 255),
            UInt8(colorB * 255),
            UInt8(opacity * 255)
        )

        // Convert quaternion to Antimatter15 format (stored as UInt8)
        // Map from [-1, 1] to [0, 255]
        let rotation_vector = quat.vectorRealFirst
        let rotation = SIMD4<UInt8>(
            UInt8(((rotation_vector.x + 1.0) * 127.5).clamped(to: 0...255)),
            UInt8(((rotation_vector.y + 1.0) * 127.5).clamped(to: 0...255)),
            UInt8(((rotation_vector.z + 1.0) * 127.5).clamped(to: 0...255)),
            UInt8(((rotation_vector.w + 1.0) * 127.5).clamped(to: 0...255))
        )

        self = Antimatter15Splat(position: position, scale: scale, color: color, rotation: rotation)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif // os(iOS) || (os(macOS) && !arch(x86_64))
