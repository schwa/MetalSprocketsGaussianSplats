import MetalSprocketsGaussianSplatShaders
import simd

// GenericSplat is imported from MetalSprocketsGaussianSplatShaders C header
extension GenericSplat: @retroactive Equatable, @unchecked @retroactive Sendable {
    public static func == (lhs: GenericSplat, rhs: GenericSplat) -> Bool {
        lhs.position == rhs.position &&
            lhs.scale == rhs.scale &&
            lhs.color == rhs.color &&
            lhs.rotation == rhs.rotation
    }
}

public extension GenericSplat {
    init(position: SIMD3<Float>, scale: SIMD3<Float>, color: SIMD4<Float>, rotation: simd_quatf) {
        self.init()
        self.position = position
        self.scale = scale
        self.color = color
        self.rotation = rotation.vector
    }
}

// Decodable conformance for GenericSplat
extension GenericSplat: @retroactive Decodable {
    enum CodingKeys: String, CodingKey {
        case position, scale, color, rotation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.position = try container.decode(SIMD3<Float>.self, forKey: .position)
        self.scale = try container.decode(SIMD3<Float>.self, forKey: .scale)
        self.color = try container.decode(SIMD4<Float>.self, forKey: .color)
        self.rotation = try container.decode(SIMD4<Float>.self, forKey: .rotation)
    }
}

// ExtendedSplat includes spherical harmonics data
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
