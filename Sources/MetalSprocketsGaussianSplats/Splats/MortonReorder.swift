import simd

/// Morton (Z-order) reordering of splat arrays at load time (#89).
///
/// Group-level hierarchical culling groups consecutive splats and culls them
/// against a per-group AABB. So the cull works well only when consecutive
/// splats are spatially coherent. PLY and SOG files are often loosely ordered.
/// A reorder along a Morton curve tightens the group AABBs, so whole groups
/// cull cleanly.
public enum SplatMortonReorder {
    /// The number of quantization bits per axis (3 × 21 = 63-bit keys).
    private static let bitsPerAxis = 21

    /// Returns the permutation that sorts `splats` into Morton order.
    ///
    /// Positions are quantized to a 21-bit-per-axis grid over the bounding box
    /// of the cloud and sorted by the interleaved (Z-order) key. The returned
    /// array maps each destination index to a source index.
    public static func mortonOrder(of splats: [some SortableSplatProtocol]) -> [Int] {
        guard splats.count > 1 else {
            return Array(splats.indices)
        }
        var minBound = splats[0].floatPosition
        var maxBound = minBound
        for splat in splats.dropFirst() {
            let position = splat.floatPosition
            minBound = simd_min(minBound, position)
            maxBound = simd_max(maxBound, position)
        }
        let extent = maxBound - minBound
        let maxCoordinate = Float((1 << bitsPerAxis) - 1)
        let scale = SIMD3<Float>(
            extent.x > 0 ? maxCoordinate / extent.x : 0,
            extent.y > 0 ? maxCoordinate / extent.y : 0,
            extent.z > 0 ? maxCoordinate / extent.z : 0
        )
        let keys = splats.map { splat -> UInt64 in
            let normalized = (splat.floatPosition - minBound) * scale
            let clamped = simd_clamp(normalized, .zero, SIMD3<Float>(repeating: maxCoordinate))
            return mortonKey(x: UInt64(clamped.x), y: UInt64(clamped.y), z: UInt64(clamped.z))
        }
        return splats.indices.sorted { keys[$0] < keys[$1] }
    }

    /// Reorders `splats` into Morton order, along with the per-splat SH
    /// coefficients when they are present. `shCoefficients` must hold
    /// `floatsPerSplat` consecutive floats per splat. It is reordered together
    /// with the splats, so each coefficient stays attached to its splat.
    public static func reorder<Splat: SortableSplatProtocol>(splats: inout [Splat], shCoefficients: inout [Float]) {
        let order = mortonOrder(of: splats)
        let floatsPerSplat = splats.isEmpty ? 0 : shCoefficients.count / splats.count
        precondition(shCoefficients.count == splats.count * floatsPerSplat, "SH coefficient count must be a multiple of the splat count")
        let sourceCoefficients = shCoefficients
        for (destination, source) in order.enumerated() where floatsPerSplat > 0 {
            for offset in 0..<floatsPerSplat {
                shCoefficients[destination * floatsPerSplat + offset] = sourceCoefficients[source * floatsPerSplat + offset]
            }
        }
        splats = order.map { splats[$0] }
    }

    /// Reorders `splats` alone into Morton order.
    public static func reorder<Splat: SortableSplatProtocol>(splats: inout [Splat]) {
        let order = mortonOrder(of: splats)
        splats = order.map { splats[$0] }
    }

    /// Interleaves three 21-bit coordinates into a 63-bit Morton key.
    static func mortonKey(x: UInt64, y: UInt64, z: UInt64) -> UInt64 {
        spread(x) | (spread(y) << 1) | (spread(z) << 2)
    }

    /// Spreads the low 21 bits of `value` so each bit lands 3 positions apart.
    private static func spread(_ value: UInt64) -> UInt64 {
        var v = value & 0x1F_FFFF
        v = (v | (v << 32)) & 0x1F_0000_0000_FFFF
        v = (v | (v << 16)) & 0x1F_0000_FF00_00FF
        v = (v | (v << 8)) & 0x100F_00F0_0F00_F00F
        v = (v | (v << 4)) & 0x10C3_0C30_C30C_30C3
        v = (v | (v << 2)) & 0x1249_2492_4924_9249
        return v
    }
}
