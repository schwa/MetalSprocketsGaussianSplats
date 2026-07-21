#if !arch(x86_64)
import Metal
@testable import MetalSprocketsGaussianSplats
import Testing

@Suite("PointSplatWorkload")
struct PointSplatWorkloadTests {
    enum TestError: Error {
        case noMetalDevice
        case bufferAllocationFailed
    }

    let device: MTLDevice
    let queue: MTLCommandQueue

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TestError.noMetalDevice
        }
        self.device = device
        self.queue = queue
    }

    private func run(counts: [UInt32], capacity: Int) throws -> (indices: [UInt32], total: Int) {
        let distributor = try PointSplatWorkloadDistributor(device: device, capacity: capacity)
        guard let countsBuffer = device.makeBuffer(bytes: counts, length: MemoryLayout<UInt32>.stride * counts.count) else {
            throw TestError.bufferAllocationFailed
        }
        let result = try distributor.build(counts: countsBuffer, count: counts.count, commandQueue: queue)

        // Result indices live in a private buffer; blit to shared for inspection.
        guard let shared = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(result.totalPoints, 1)), let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw TestError.bufferAllocationFailed
        }
        if result.totalPoints > 0 {
            blit.copy(from: result.indices, sourceOffset: 0, to: shared, destinationOffset: 0, size: MemoryLayout<UInt32>.stride * result.totalPoints)
        }
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pointer = shared.contents().bindMemory(to: UInt32.self, capacity: result.totalPoints)
        return (Array(UnsafeBufferPointer(start: pointer, count: result.totalPoints)), result.totalPoints)
    }

    private func referenceIndices(counts: [UInt32]) -> [UInt32] {
        var expected = [UInt32]()
        for (gaussian, count) in counts.enumerated() {
            expected.append(contentsOf: [UInt32](repeating: UInt32(gaussian), count: Int(count)))
        }
        return expected
    }

    @Test("paper Fig. 2 example")
    func paperExample() throws {
        // Counts [2,1,0,4,0,1] -> indices [0,0,1,3,3,3,3,5]
        let (indices, total) = try run(counts: [2, 1, 0, 4, 0, 1], capacity: 10)
        #expect(total == 8)
        #expect(indices == [0, 0, 1, 3, 3, 3, 3, 5])
    }

    @Test("empty counts produce zero points")
    func emptyCounts() throws {
        let (indices, total) = try run(counts: [0, 0, 0, 0], capacity: 16)
        #expect(total == 0)
        #expect(indices.isEmpty)
    }

    @Test("first Gaussian with zero count")
    func leadingZeroCount() throws {
        let (indices, total) = try run(counts: [0, 3, 0, 2], capacity: 16)
        #expect(total == 5)
        #expect(indices == [1, 1, 1, 3, 3])
    }

    @Test("multi-block distribution matches reference")
    func multiBlock() throws {
        // Spans several 256-element scan blocks with a mix of zeros and counts.
        var generator = SystemRandomNumberGenerator()
        let counts = (0..<2_000).map { _ in UInt32.random(in: 0...4, using: &generator) }
        let expected = referenceIndices(counts: counts)
        let (indices, total) = try run(counts: counts, capacity: expected.count + 100)
        #expect(total == expected.count)
        #expect(indices == expected)
    }

    @Test("large single Gaussian spanning many blocks")
    func largeSingleGaussian() throws {
        let counts: [UInt32] = [0, 5_000, 1]
        let (indices, total) = try run(counts: counts, capacity: 6_000)
        #expect(total == 5_001)
        #expect(indices == referenceIndices(counts: counts))
    }
}
#endif
