import simd

struct BoundingBox {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var size: SIMD3<Float> {
        max - min
    }

    var center: SIMD3<Float> {
        (min + max) / 2
    }

    static let empty = BoundingBox(
        min: SIMD3<Float>(repeating: .infinity),
        max: SIMD3<Float>(repeating: -.infinity)
    )

    mutating func expand(by point: SIMD3<Float>) {
        min = simd.min(min, point)
        max = simd.max(max, point)
    }
}
