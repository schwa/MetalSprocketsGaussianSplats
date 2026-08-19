import simd

/// A generic splat, used as an intermediate format when the code reads splat files.
///
/// This is a CPU-side struct for file I/O. Each renderer converts it to its own GPU format.
public struct GenericSplat: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var color: SIMD4<Float>
    public var rotation: SIMD4<Float>

    public init(position: SIMD3<Float> = .zero, scale: SIMD3<Float> = .zero, color: SIMD4<Float> = .zero, rotation: SIMD4<Float> = .init(0, 0, 0, 1)) {
        self.position = position
        self.scale = scale
        self.color = color
        self.rotation = rotation
    }

    public init(position: SIMD3<Float>, scale: SIMD3<Float>, color: SIMD4<Float>, rotation: simd_quatf) {
        self.position = position
        self.scale = scale
        self.color = color
        self.rotation = rotation.vector
    }
}

// MARK: - Decodable

extension GenericSplat: Decodable {
    enum CodingKeys: String, CodingKey {
        case position, scale, color, rotation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.position = try container.decode(SIMD3<Float>.self, forKey: .position)
        self.scale = try container.decode(SIMD3<Float>.self, forKey: .scale)
        self.color = try container.decode(SIMD4<Float>.self, forKey: .color)
        self.rotation = try container.decode(SIMD4<Float>.self, forKey: .rotation)
    }
}

// MARK: - ExtendedSplat

/// A splat with spherical harmonics data.
///
/// Each inner array in `sphericalHarmonics` has 3 floats (RGB) for one SH basis function.
/// Degree 1 has 3 coefficients, degree 2 has 8, and degree 3 has 15.
public struct ExtendedSplat: Equatable, Sendable {
    public var genericSplat: GenericSplat
    public var sphericalHarmonics: [[Float]]?

    public init(genericSplat: GenericSplat, sphericalHarmonics: [[Float]]? = nil) {
        self.genericSplat = genericSplat
        self.sphericalHarmonics = sphericalHarmonics
    }

    public init(position: SIMD3<Float>, scale: SIMD3<Float>, color: SIMD4<Float>, rotation: simd_quatf, sphericalHarmonics: [[Float]]? = nil) {
        self.genericSplat = GenericSplat(position: position, scale: scale, color: color, rotation: rotation)
        self.sphericalHarmonics = sphericalHarmonics
    }
}
