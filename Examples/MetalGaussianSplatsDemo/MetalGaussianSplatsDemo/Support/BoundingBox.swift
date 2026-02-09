import simd

nonisolated
struct BoundingBox {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var size: SIMD3<Float> {
        max - min
    }

    var center: SIMD3<Float> {
        (min + max) / 2
    }

    /// Returns the 8 corners of the bounding box
    /// Order: bottom (0-3), top (4-7), with consistent winding
    var corners: [SIMD3<Float>] {
        [
            SIMD3(min.x, min.y, min.z), // 0: bottom-left-front
            SIMD3(max.x, min.y, min.z), // 1: bottom-right-front
            SIMD3(min.x, min.y, max.z), // 2: bottom-left-back
            SIMD3(max.x, min.y, max.z), // 3: bottom-right-back
            SIMD3(min.x, max.y, min.z), // 4: top-left-front
            SIMD3(max.x, max.y, min.z), // 5: top-right-front
            SIMD3(min.x, max.y, max.z), // 6: top-left-back
            SIMD3(max.x, max.y, max.z) // 7: top-right-back
        ]
    }

    static let empty = Self(
        min: SIMD3<Float>(repeating: .infinity),
        max: SIMD3<Float>(repeating: -.infinity)
    )

    mutating func expand(by point: SIMD3<Float>) {
        min = simd.min(min, point)
        max = simd.max(max, point)
    }
}
