import Foundation
import simd

/// Reader for PLY files containing Gaussian splat data
/// Wraps PLYReader and converts records to GenericSplat
public struct PLYSplatReader: SplatReader {
    private let plyReader: PLYReader

    /// The degree of spherical harmonics detected in the file (0 = none, 1-3 = higher-order SH)
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
        var index = 0
        let degree = shDegree
        try plyReader.read { record in
            guard let splat = GenericSplat(plyRecord: record) else {
                throw SplatsError.invalidRecord(index)
            }
            let sh = Self.extractSphericalHarmonics(from: record, degree: degree)
            try handler(index, ExtendedSplat(genericSplat: splat, sphericalHarmonics: sh))
            index += 1
        }
    }

    // MARK: - Private

    /// Detects SH degree by checking which f_rest_N properties exist
    /// - Degree 1: 3 coefficients (indices 0-8, but DC is separate, so f_rest_0 to f_rest_8)
    /// - Degree 2: 8 coefficients (indices 0-23, so f_rest_0 to f_rest_23)
    /// - Degree 3: 15 coefficients (indices 0-44, so f_rest_0 to f_rest_44)
    ///
    /// Actually the standard 3DGS PLY format stores:
    /// - f_dc_0, f_dc_1, f_dc_2: DC (degree 0) coefficients for R, G, B
    /// - f_rest_0 to f_rest_N: Higher order SH coefficients
    ///
    /// For degree 3 (15 basis functions total, minus 1 DC = 14 higher order):
    /// 14 coefficients * 3 channels = 42 values -> f_rest_0 to f_rest_44 (45 total, but some implementations vary)
    private static func detectSHDegree(from reader: PLYReader) -> UInt8 {
        guard let element = reader.primaryElement else { return 0 }

        let propertyNames = Set(element.properties.map(\.name))

        // Check for f_rest properties to determine SH degree
        // Degree 1: 3 basis functions (minus DC) = 3 * 3 = 9 values -> f_rest_0 to f_rest_8
        // Degree 2: 8 basis functions (minus DC) = 8 * 3 = 24 values -> f_rest_0 to f_rest_23
        // Degree 3: 15 basis functions (minus DC) = 15 * 3 = 45 values -> f_rest_0 to f_rest_44
        //
        // But actually, the way 3DGS stores it:
        // - DC (l=0): 1 coefficient per channel = 3 total (f_dc_0, f_dc_1, f_dc_2)
        // - Degree 1 (l=1): 3 coefficients per channel = 9 total
        // - Degree 2 (l=2): 5 coefficients per channel = 15 total
        // - Degree 3 (l=3): 7 coefficients per channel = 21 total
        //
        // So for "degree 3" (using all bands 1-3):
        // (3 + 5 + 7) * 3 = 45 f_rest values

        // Check from highest to lowest degree
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

    /// Extracts SH coefficients from a PLY record
    /// Returns array of [R, G, B] for each basis function (excluding DC)
    private static func extractSphericalHarmonics(from record: PLYReader.Record, degree: UInt8) -> [[Float]]? {
        guard degree > 0 else { return nil }

        // Number of coefficients (basis functions) per degree, excluding DC:
        // Degree 1: 3 (l=1 has 3 basis functions)
        // Degree 2: 3 + 5 = 8 (l=1 + l=2)
        // Degree 3: 3 + 5 + 7 = 15 (l=1 + l=2 + l=3)
        let numCoeffs: Int
        switch degree {
        case 1: numCoeffs = 3
        case 2: numCoeffs = 8
        case 3: numCoeffs = 15
        default: return nil
        }

        // PLY stores SH in a different order than we need
        // PLY f_rest layout: all R values, then all G values, then all B values
        // We need: [[R0,G0,B0], [R1,G1,B1], ...]

        var coefficients: [[Float]] = []
        coefficients.reserveCapacity(numCoeffs)

        for i in 0..<numCoeffs {
            // PLY stores: f_rest_0..f_rest_(n-1) for R, f_rest_n..f_rest_(2n-1) for G, etc.
            let rIndex = i
            let gIndex = i + numCoeffs
            let bIndex = i + numCoeffs * 2

            guard let r = record["f_rest_\(rIndex)"]?.floatValue,
                  let g = record["f_rest_\(gIndex)"]?.floatValue,
                  let b = record["f_rest_\(bIndex)"]?.floatValue else {
                // If we can't get all values, return nil for this splat
                return nil
            }

            coefficients.append([r, g, b])
        }

        return coefficients
    }
}

// MARK: - GenericSplat PLY Conversion

public extension GenericSplat {
    /// Initializes a GenericSplat from a PLY record
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
        let opacity: Float
        if let rawOpacity = record["opacity"]?.floatValue {
            // Apply sigmoid to convert from logit space
            opacity = 1.0 / (1.0 + exp(-rawOpacity))
        } else {
            opacity = record["alpha"]?.floatValue ?? 1.0
        }

        // Extract rotation - quaternion (w, x, y, z) - standard 3DGS PLY order
        let rotW = record["rot_0"]?.floatValue ?? 1.0
        let rotX = record["rot_1"]?.floatValue ?? 0.0
        let rotY = record["rot_2"]?.floatValue ?? 0.0
        let rotZ = record["rot_3"]?.floatValue ?? 0.0

        // Normalize quaternion
        let rotation = simd_quatf(ix: rotX, iy: rotY, iz: rotZ, r: rotW).normalized

        self.init(
            position: SIMD3<Float>(x, y, z),
            scale: SIMD3<Float>(exp(scaleX), exp(scaleY), exp(scaleZ)),
            color: SIMD4<Float>(colorR, colorG, colorB, opacity.clamped(to: 0...1)),
            rotation: rotation
        )
    }
}
