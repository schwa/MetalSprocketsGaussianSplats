import GeometryLite3D
import simd

public struct GenericSplat: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var color: SIMD4<Float>
    public var rotation: simd_quatf
    public var sphericalHarmonics: [[Float]]?

    public init(position: SIMD3<Float>, scale: SIMD3<Float>, color: SIMD4<Float>, rotation: simd_quatf, sphericalHarmonics: [[Float]]? = nil) {
        self.position = position
        self.scale = scale
        self.color = color
        self.rotation = rotation
        self.sphericalHarmonics = sphericalHarmonics
    }
}

extension GenericSplat: Decodable {
    enum CodingKeys: String, CodingKey {
        case position
        case scale
        case color
        case rotation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decode(SIMD3<Float>.self, forKey: .position)
        scale = try container.decode(SIMD3<Float>.self, forKey: .scale)
        color = try container.decode(SIMD4<Float>.self, forKey: .color)
        let rotationVector = try container.decode(SIMD4<Float>.self, forKey: .rotation)
        rotation = simd_quatf(angle: rotationVector.w, axis: SIMD3<Float>(rotationVector.x, rotationVector.y, rotationVector.z))
    }
}

extension simd_float4 {
    var length: Scalar {
        simd_length(self)
    }
}

extension SIMD4 where Scalar == Float {
    func clamped(to range: ClosedRange<Scalar>) -> Self {
        Self(map { $0.clamped(to: range) })
    }
}

extension simd_quatf {
    var vectorRealFirst: simd_float4 {
        [vector.w, vector.x, vector.y, vector.z]
    }
}
