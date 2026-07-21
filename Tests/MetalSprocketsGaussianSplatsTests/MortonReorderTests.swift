#if !arch(x86_64)

@testable import MetalSprocketsGaussianSplats
import simd
import Testing

private struct TestSplat: SortableSplatProtocol {
    var floatPosition: SIMD3<Float>
    var id: Int
}

@Suite("SplatMortonReorder")
struct MortonReorderTests {
    @Test("Morton keys interleave bits correctly")
    func mortonKeyInterleaving() {
        #expect(SplatMortonReorder.mortonKey(x: 0, y: 0, z: 0) == 0)
        #expect(SplatMortonReorder.mortonKey(x: 1, y: 0, z: 0) == 0b001)
        #expect(SplatMortonReorder.mortonKey(x: 0, y: 1, z: 0) == 0b010)
        #expect(SplatMortonReorder.mortonKey(x: 0, y: 0, z: 1) == 0b100)
        #expect(SplatMortonReorder.mortonKey(x: 0b11, y: 0, z: 0) == 0b001_001)
        // Top bit of each 21-bit axis lands in the top three key bits.
        #expect(SplatMortonReorder.mortonKey(x: 1 << 20, y: 1 << 20, z: 1 << 20) == 0b111 << 60)
    }

    @Test("Reorder groups spatially clustered splats together")
    func reorderClusters() {
        // Two well-separated clusters, interleaved in file order.
        var splats: [TestSplat] = []
        for index in 0..<8 {
            let jitter = Float(index) * 0.01
            splats.append(TestSplat(floatPosition: SIMD3<Float>(jitter, jitter, 0), id: index * 2))
            splats.append(TestSplat(floatPosition: SIMD3<Float>(100 + jitter, 100 + jitter, 100), id: index * 2 + 1))
        }
        SplatMortonReorder.reorder(splats: &splats)
        // After reordering, each cluster occupies one contiguous half.
        let firstHalfIDs = Set(splats.prefix(8).map(\.id))
        #expect(firstHalfIDs == Set(stride(from: 0, to: 16, by: 2)) || firstHalfIDs == Set(stride(from: 1, to: 16, by: 2)))
        // Reordering is a permutation: nothing lost or duplicated.
        #expect(Set(splats.map(\.id)) == Set(0..<16))
    }

    @Test("SH coefficients are reordered in lockstep with splats")
    func shCoefficientsFollowSplats() {
        var splats = [
            TestSplat(floatPosition: SIMD3<Float>(10, 10, 10), id: 0),
            TestSplat(floatPosition: SIMD3<Float>(0, 0, 0), id: 1),
            TestSplat(floatPosition: SIMD3<Float>(5, 5, 5), id: 2),
        ]
        // 3 floats per splat, tagged by original splat id.
        var shCoefficients: [Float] = [0, 0.1, 0.2, 1, 1.1, 1.2, 2, 2.1, 2.2]
        SplatMortonReorder.reorder(splats: &splats, shCoefficients: &shCoefficients)
        for (index, splat) in splats.enumerated() {
            let base = Float(splat.id)
            #expect(shCoefficients[index * 3] == base)
            #expect(shCoefficients[index * 3 + 1] == base + 0.1)
            #expect(shCoefficients[index * 3 + 2] == base + 0.2)
        }
    }

    @Test("Degenerate inputs are handled")
    func degenerateInputs() {
        var empty: [TestSplat] = []
        SplatMortonReorder.reorder(splats: &empty)
        #expect(empty.isEmpty)

        // All splats at one point: any order is valid, but count is preserved.
        var coincident = (0..<4).map { TestSplat(floatPosition: SIMD3<Float>(1, 2, 3), id: $0) }
        SplatMortonReorder.reorder(splats: &coincident)
        #expect(Set(coincident.map(\.id)) == Set(0..<4))
    }
}

#endif
