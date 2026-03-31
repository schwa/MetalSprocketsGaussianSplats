#if !arch(x86_64)
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

// MARK: - Helpers

private func makeCloud(device: MTLDevice, count: Int) throws -> GPUSplatCloud<SparkSplat> {
    let splats = (0..<count).map { i -> SparkSplat in
        let pos = simd_half3(Float16(i), 0, 0)
        return SparkSplat(
            position: pos,
            scale: simd_half3(repeating: 0.1),
            rotation: simd_half4(0, 0, 0, 1),
            color: simd_uchar4(128, 128, 128, 255)
        )
    }
    return try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
}

// MARK: - Tests

@Suite("AsyncSortManager cloud switching")
struct AsyncSortManagerSwitchTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available")
            throw AsyncSortManagerSwitchError.noMetalDevice
        }
        self.device = device
    }

    // MARK: -

    @Test("setSplatCloud replaces active cloud")
    func setSplatCloudReplacesCloud() async throws {
        let cloudA = try makeCloud(device: device, count: 10)
        let cloudB = try makeCloud(device: device, count: 20)

        let sortManager = try AsyncSortManager<SparkSplat>(device: device, splatCloud: cloudA, capacity: cloudA.count)

        await sortManager.setSplatCloud(cloudB)

        // The sorter capacity must have grown to fit cloudB
        let capacity = await sortManager.sorterCapacity
        #expect(capacity >= cloudB.count)
    }

    @Test("setSplatClouds grows capacity for larger cloud")
    func setSplatCloudsGrowsCapacity() async throws {
        let cloudA = try makeCloud(device: device, count: 5)
        let cloudB = try makeCloud(device: device, count: 100)

        let sortManager = try AsyncSortManager<SparkSplat>(device: device, splatCloud: cloudA, capacity: cloudA.count)

        await sortManager.setSplatCloud(cloudB)

        let capacity = await sortManager.sorterCapacity
        #expect(capacity >= 100)
    }

    @Test("setSplatClouds does not shrink capacity for smaller cloud")
    func setSplatCloudsDoesNotShrinkCapacity() async throws {
        let cloudA = try makeCloud(device: device, count: 50)
        let cloudB = try makeCloud(device: device, count: 10)

        let sortManager = try AsyncSortManager<SparkSplat>(device: device, splatCloud: cloudA, capacity: cloudA.count)

        await sortManager.setSplatCloud(cloudB)

        let capacity = await sortManager.sorterCapacity
        #expect(capacity >= 50, "Capacity should not shrink when switching to a smaller cloud")
    }

    @Test("currentSortedIndices is preserved after cloud switch")
    func currentSortedIndicesPreservedAfterSwitch() async throws {
        let cloudA = try makeCloud(device: device, count: 10)
        let cloudB = try makeCloud(device: device, count: 20)

        let sortManager = try AsyncSortManager<SparkSplat>(device: device, splatCloud: cloudA, capacity: cloudA.count)

        // Perform an initial sort so currentSortedIndices is non-nil
        let params = SortParameters(camera: .identity, model: .identity)
        _ = sortManager.sortNowSync(params)

        let indicesBefore = await sortManager.currentSortedIndices
        #expect(indicesBefore != nil, "Expected non-nil indices after initial sort")

        // Switch cloud — indices must NOT be cleared
        await sortManager.setSplatCloud(cloudB)

        let indicesAfter = await sortManager.currentSortedIndices
        #expect(indicesAfter != nil, "currentSortedIndices must not be cleared on cloud switch to avoid blank frames")
    }

    @Test("sort after cloud switch returns correct splat count")
    func sortAfterSwitchReturnsCorrectCount() async throws {
        let cloudA = try makeCloud(device: device, count: 10)
        let cloudB = try makeCloud(device: device, count: 25)

        let sortManager = try AsyncSortManager<SparkSplat>(device: device, splatCloud: cloudA, capacity: cloudB.count)

        await sortManager.setSplatCloud(cloudB)

        let params = SortParameters(camera: .identity, model: .identity)
        let indices = sortManager.sortNowSync(params)

        #expect(indices.indices.count == cloudB.count)
    }
}

// MARK: -

private enum AsyncSortManagerSwitchError: Error {
    case noMetalDevice
}
#endif
