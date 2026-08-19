#if !arch(x86_64)
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

@Suite("AsyncSortManager managed stream")
struct ManagedSortedIndicesStreamTests {
    enum TestError: Error {
        case noMetalDevice
    }

    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestError.noMetalDevice
        }
        self.device = device
    }

    private func makeCloud(count: Int) throws -> GPUSplatCloud<SparkSplat> {
        let splats = (0..<count).map { i -> SparkSplat in
            SparkSplat(
                position: simd_half3(Float16(i), 0, 0),
                scale: simd_half3(repeating: 0.1),
                rotation: simd_half4(0, 0, 0, 1),
                color: simd_uchar4(128, 128, 128, 255)
            )
        }
        return try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
    }

    @Test("managedSortedIndicesStream yields results and releases superseded buffers")
    func managedStreamReleasesSupersededBuffers() async throws {
        let cloud = try makeCloud(count: 10)
        let preallocated = 3
        let sortManager = try AsyncSortManager<SparkSplat>(
            device: device,
            splatCloud: cloud,
            capacity: cloud.count,
            preallocatedBufferCount: preallocated
        )

        let consumer = Task {
            var received = 0
            for await _ in sortManager.managedSortedIndicesStream(pendingReleaseDepth: 0) {
                received += 1
            }
            return received
        }

        let sortCount = 5
        let parameters = SortParameters(camera: .identity, model: .identity)
        for _ in 0 ..< sortCount {
            _ = await sortManager.sortNowAsync(parameters)
            // The sleep lets the consumer keep up so no yields are dropped.
            try await Task.sleep(for: .milliseconds(20))
        }

        // At depth 0, all superseded buffers return to the pool. Only the latest
        // buffer is still held. The poll avoids timing flakiness.
        let pool = await sortManager.indexBufferPool
        var deadline = 100
        while pool.availableCount < pool.totalAllocatedCount - 1, deadline > 0 {
            try await Task.sleep(for: .milliseconds(10))
            deadline -= 1
        }
        #expect(pool.availableCount == pool.totalAllocatedCount - 1)

        consumer.cancel()
        _ = await consumer.value
    }

    @Test("managedSortedIndicesStream releases pending buffers when iteration ends")
    func managedStreamReleasesOnTermination() async throws {
        let cloud = try makeCloud(count: 10)
        let sortManager = try AsyncSortManager<SparkSplat>(
            device: device,
            splatCloud: cloud,
            capacity: cloud.count,
            preallocatedBufferCount: 4
        )

        let consumer = Task {
            // A large depth releases nothing during iteration.
            for await _ in sortManager.managedSortedIndicesStream(pendingReleaseDepth: 100) {
                // Consume without release. The depth check runs after cancellation.
            }
        }

        let parameters = SortParameters(camera: .identity, model: .identity)
        for _ in 0 ..< 3 {
            _ = await sortManager.sortNowAsync(parameters)
            try await Task.sleep(for: .milliseconds(20))
        }

        consumer.cancel()
        await consumer.value

        // After cancellation, all buffers except the last-yielded one release.
        let pool = await sortManager.indexBufferPool
        var deadline = 100
        while pool.availableCount < pool.totalAllocatedCount - 1, deadline > 0 {
            try await Task.sleep(for: .milliseconds(10))
            deadline -= 1
        }
        #expect(pool.availableCount == pool.totalAllocatedCount - 1)
    }
}
#endif
