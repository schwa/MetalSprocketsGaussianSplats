#if !arch(x86_64)
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Testing

/// Regression tests for the per-tile depth sort (#61).
///
/// tile_sort must order each tile's entries front-to-back. Camera-space z is
/// negative in front of the camera, so a larger value is closer. The sort must
/// be stable for equal depths.
@Suite("TileSplatSort ordering", .enabled(if: MetalTestSupport.supports64BitAtomics))
struct TileSplatSortTests {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
        self.queue = try #require(device.makeCommandQueue())
        let library = try device.makeDefaultLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        let function = try #require(library.makeFunction(name: "TileSplatSort::tile_sort"))
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Runs tile_sort over the given entries and per-tile offsets, and returns
    /// the sorted entries. The result lands back in buffer A after 4 passes.
    private func runSort(entries: [TileSplatIndex], tileOffsets: [UInt32]) throws -> [TileSplatIndex] {
        let numTiles = tileOffsets.count - 1
        let byteCount = entries.count * MemoryLayout<TileSplatIndex>.stride
        let bufferA = try #require(device.makeBuffer(bytes: entries, length: byteCount))
        let bufferB = try #require(device.makeBuffer(length: byteCount))
        let offsets = try #require(tileOffsets.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })

        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(bufferA, offset: 0, index: 0)
        encoder.setBuffer(bufferB, offset: 0, index: 1)
        encoder.setBuffer(offsets, offset: 0, index: 2)
        var count = UInt32(numTiles)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: numTiles, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(numTiles, 64), height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pointer = bufferA.contents().bindMemory(to: TileSplatIndex.self, capacity: entries.count)
        return Array(UnsafeBufferPointer(start: pointer, count: entries.count))
    }

    @Test("each tile is sorted front-to-back (descending camera-space z)")
    func sortsFrontToBackPerTile() throws {
        // Two tiles with shuffled negative depths. -0.5 is closest to the camera.
        let tile0: [Float] = [-3.0, -0.5, -7.25, -1.5, -100.0]
        let tile1: [Float] = [-2.0, -9.0, -0.75, -4.5]
        let entries = (tile0 + tile1).enumerated().map { TileSplatIndex(splatID: UInt32($0.offset), depth: $0.element) }
        let offsets: [UInt32] = [0, UInt32(tile0.count), UInt32(tile0.count + tile1.count)]

        let sorted = try runSort(entries: entries, tileOffsets: offsets)

        let sorted0 = sorted[0..<tile0.count].map(\.depth)
        let sorted1 = sorted[tile0.count...].map(\.depth)
        #expect(sorted0 == tile0.sorted(by: >))
        #expect(sorted1 == tile1.sorted(by: >))
    }

    @Test("sort is stable for equal depths")
    func stableForEqualDepths() throws {
        let entries = [
            TileSplatIndex(splatID: 10, depth: -2.0),
            TileSplatIndex(splatID: 11, depth: -1.0),
            TileSplatIndex(splatID: 12, depth: -2.0),
            TileSplatIndex(splatID: 13, depth: -1.0),
            TileSplatIndex(splatID: 14, depth: -2.0)
        ]
        let sorted = try runSort(entries: entries, tileOffsets: [0, UInt32(entries.count)])
        #expect(sorted.map(\.splatID) == [11, 13, 10, 12, 14])
        #expect(sorted.map(\.depth) == [-1.0, -1.0, -2.0, -2.0, -2.0])
    }
}
#endif
