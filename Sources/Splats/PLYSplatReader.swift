import Foundation
import simd

/// Reads a PLY file with Gaussian splat data.
///
/// Wraps ``PLYReader`` and converts each record to a ``GenericSplat``.
public struct PLYSplatReader: SplatReaderProtocol {
    private let plyReader: PLYReader

    /// The spherical harmonics degree found in the file. 0 means none. 1 to 3 are higher-order SH.
    public let shDegree: UInt8

    public var splatCount: Int {
        plyReader.recordCount
    }

    public init(data: Data) throws {
        self.plyReader = try PLYReader(data: data)
        self.shDegree = Self.detectSHDegree(from: plyReader)
    }

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(data: data)
    }

    public func read(_ handler: (Int, ExtendedSplat) throws -> Void) throws {
        guard let element = plyReader.primaryElement else {
            throw SplatsError.noElements
        }
        let layout = Layout(properties: element.properties, degree: shDegree)
        var index = 0
        let numCoeffs = layout.fRest.count / 3
        // Scratch reused across records; COW protects handlers that retain it.
        var shScratch: [[Float]] = Array(repeating: [0, 0, 0], count: numCoeffs)
        try plyReader.readFloatValues(element: element) { values in
            guard let splat = layout.genericSplat(from: values) else {
                throw SplatsError.invalidRecord(index)
            }
            let sh: [[Float]]? = numCoeffs > 0 && layout.fillSphericalHarmonics(from: values, into: &shScratch) ? shScratch : nil
            try handler(index, ExtendedSplat(genericSplat: splat, sphericalHarmonics: sh))
            index += 1
        }
    }

    /// Property indices resolved once so per-record decoding avoids dictionaries.
    private struct Layout {
        var x: Int?
        var y: Int?
        var z: Int?
        var scale: [Int?]
        var fdc: [Int?]
        var rgb: [Int?]
        var opacity: Int?
        var alpha: Int?
        var rot: [Int?]
        var fRest: [Int?]

        init(properties: [PLYReader.Property], degree: UInt8) {
            var indices: [String: Int] = [:]
            indices.reserveCapacity(properties.count)
            for (index, property) in properties.enumerated() {
                indices[property.name] = index
            }
            x = indices["x"]
            y = indices["y"]
            z = indices["z"]
            scale = [indices["scale_0"] ?? indices["sx"], indices["scale_1"] ?? indices["sy"], indices["scale_2"] ?? indices["sz"]]
            fdc = [indices["f_dc_0"], indices["f_dc_1"], indices["f_dc_2"]]
            rgb = [indices["red"], indices["green"], indices["blue"]]
            opacity = indices["opacity"]
            alpha = indices["alpha"]
            rot = [indices["rot_0"], indices["rot_1"], indices["rot_2"], indices["rot_3"]]

            let numCoeffs: Int
            switch degree {
            case 1:
                numCoeffs = 3
            case 2:
                numCoeffs = 8
            case 3:
                numCoeffs = 15
            default:
                numCoeffs = 0
            }
            fRest = (0..<(numCoeffs * 3)).map { indices["f_rest_\($0)"] }
        }

        private func float(_ values: [Float?], _ index: Int?) -> Float? {
            guard let index else {
                return nil
            }
            return values[index]
        }

        func genericSplat(from values: [Float?]) -> GenericSplat? {
            guard let x = float(values, x), let y = float(values, y), let z = float(values, z) else {
                return nil
            }

            let scaleX = float(values, scale[0]) ?? 0.0
            let scaleY = float(values, scale[1]) ?? 0.0
            let scaleZ = float(values, scale[2]) ?? 0.0

            let colorR: Float
            let colorG: Float
            let colorB: Float

            if let fdc0 = float(values, fdc[0]), let fdc1 = float(values, fdc[1]), let fdc2 = float(values, fdc[2]) {
                // Convert the SH DC coefficient to color with the C0 basis constant.
                let SH_C0: Float = 0.28209479177387814
                colorR = (fdc0 * SH_C0 + 0.5).clamped(to: 0...1)
                colorG = (fdc1 * SH_C0 + 0.5).clamped(to: 0...1)
                colorB = (fdc2 * SH_C0 + 0.5).clamped(to: 0...1)
            } else if let red = float(values, rgb[0]), let green = float(values, rgb[1]), let blue = float(values, rgb[2]) {
                // Normalize when the values are in the 0-255 range.
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
                colorR = 1.0
                colorG = 1.0
                colorB = 1.0
            }

            let opacityValue: Float
            if let rawOpacity = float(values, opacity) {
                // Sigmoid converts from logit space.
                opacityValue = 1.0 / (1.0 + exp(-rawOpacity))
            } else {
                opacityValue = float(values, alpha) ?? 1.0
            }

            // Quaternion in the standard 3DGS PLY order (w, x, y, z).
            let rotW = float(values, rot[0]) ?? 1.0
            let rotX = float(values, rot[1]) ?? 0.0
            let rotY = float(values, rot[2]) ?? 0.0
            let rotZ = float(values, rot[3]) ?? 0.0

            let rotation = simd_quatf(ix: rotX, iy: rotY, iz: rotZ, r: rotW).normalized

            return GenericSplat(
                position: SIMD3<Float>(x, y, z),
                scale: SIMD3<Float>(exp(scaleX), exp(scaleY), exp(scaleZ)),
                color: SIMD4<Float>(colorR, colorG, colorB, opacityValue.clamped(to: 0...1)),
                rotation: rotation
            )
        }

        func fillSphericalHarmonics(from values: [Float?], into coefficients: inout [[Float]]) -> Bool {
            let numCoeffs = fRest.count / 3
            // PLY f_rest is planar (all R, then all G, then all B). The output is interleaved [[R,G,B], ...].
            for i in 0..<numCoeffs {
                guard let r = float(values, fRest[i]), let g = float(values, fRest[i + numCoeffs]), let b = float(values, fRest[i + numCoeffs * 2]) else {
                    return false
                }
                coefficients[i][0] = r
                coefficients[i][1] = g
                coefficients[i][2] = b
            }
            return true
        }
    }

    // MARK: - Private

    /// Finds the SH degree from the `f_rest_N` properties in the file.
    ///
    /// The 3DGS PLY format stores the DC term in `f_dc_0`, `f_dc_1`, and `f_dc_2`.
    /// It stores the higher-order coefficients in `f_rest_0` to `f_rest_N`.
    /// Each degree adds coefficients per channel: 3 for l=1, 5 for l=2, 7 for l=3.
    /// So degree 1 has 9 `f_rest` values, degree 2 has 24, and degree 3 has 45.
    private static func detectSHDegree(from reader: PLYReader) -> UInt8 {
        guard let element = reader.primaryElement else {
            return 0
        }

        let propertyNames = Set(element.properties.map(\.name))

        if propertyNames.contains("f_rest_44") {
            return 3
        }
        if propertyNames.contains("f_rest_23") {
            return 2
        }
        if propertyNames.contains("f_rest_8") {
            return 1
        }

        return 0
    }
}

// MARK: - GenericSplat PLY Conversion

public extension GenericSplat {
    /// Creates a ``GenericSplat`` from a PLY record.
    ///
    /// Reads the standard Gaussian splat PLY properties:
    /// - Position: `x`, `y`, `z`
    /// - Scale: `scale_0`, `scale_1`, `scale_2`
    /// - Color: `f_dc_0`, `f_dc_1`, `f_dc_2`, or `red`, `green`, `blue`
    /// - Rotation: `rot_0`, `rot_1`, `rot_2`, `rot_3` (a quaternion)
    /// - Opacity: `opacity`
    init?(plyRecord record: PLYReader.Record) {
        guard let x = record["x"]?.floatValue, let y = record["y"]?.floatValue, let z = record["z"]?.floatValue else {
            return nil
        }

        // scale_0/1/2, with sx/sy/sz as the fallback.
        let scaleX = record["scale_0"]?.floatValue ?? record["sx"]?.floatValue ?? 0.0
        let scaleY = record["scale_1"]?.floatValue ?? record["sy"]?.floatValue ?? 0.0
        let scaleZ = record["scale_2"]?.floatValue ?? record["sz"]?.floatValue ?? 0.0

        // f_dc_0/1/2 (Gaussian splat format), with red/green/blue as the fallback.
        let colorR: Float
        let colorG: Float
        let colorB: Float

        if let fdc0 = record["f_dc_0"]?.floatValue, let fdc1 = record["f_dc_1"]?.floatValue, let fdc2 = record["f_dc_2"]?.floatValue {
            // Convert the SH DC coefficient to color with the C0 basis constant.
            let SH_C0: Float = 0.28209479177387814
            colorR = (fdc0 * SH_C0 + 0.5).clamped(to: 0...1)
            colorG = (fdc1 * SH_C0 + 0.5).clamped(to: 0...1)
            colorB = (fdc2 * SH_C0 + 0.5).clamped(to: 0...1)
        } else if let red = record["red"]?.floatValue, let green = record["green"]?.floatValue, let blue = record["blue"]?.floatValue {
            // Normalize when the values are in the 0-255 range.
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
            colorR = 1.0
            colorG = 1.0
            colorB = 1.0
        }

        let opacity: Float
        if let rawOpacity = record["opacity"]?.floatValue {
            // Sigmoid converts from logit space.
            opacity = 1.0 / (1.0 + exp(-rawOpacity))
        } else {
            opacity = record["alpha"]?.floatValue ?? 1.0
        }

        // Quaternion in the standard 3DGS PLY order (w, x, y, z).
        let rotW = record["rot_0"]?.floatValue ?? 1.0
        let rotX = record["rot_1"]?.floatValue ?? 0.0
        let rotY = record["rot_2"]?.floatValue ?? 0.0
        let rotZ = record["rot_3"]?.floatValue ?? 0.0

        let rotation = simd_quatf(ix: rotX, iy: rotY, iz: rotZ, r: rotW).normalized

        self.init(
            position: SIMD3<Float>(x, y, z),
            scale: SIMD3<Float>(exp(scaleX), exp(scaleY), exp(scaleZ)),
            color: SIMD4<Float>(colorR, colorG, colorB, opacity.clamped(to: 0...1)),
            rotation: rotation
        )
    }
}
