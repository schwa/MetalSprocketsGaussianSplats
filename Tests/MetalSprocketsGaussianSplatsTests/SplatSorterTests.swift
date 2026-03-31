#if !arch(x86_64)
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats
import Testing

// MARK: - Helpers

private func makeSplat(x: Float) -> SparkSplat {
    SparkSplat(
        position: simd_half3(Float16(x), 0, 0),
        scale: simd_half3(repeating: 0.1),
        rotation: simd_half4(0, 0, 0, 1),
        color: simd_uchar4(128, 128, 128, 255)
    )
}

private func makeCloud(device: MTLDevice, positions: [Float]) throws -> GPUSplatCloud<SparkSplat> {
    let splats = positions.map { makeSplat(x: $0) }
    return try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
}

// MARK: - Tests

@Suite("SplatSorter")
struct SplatSorterTests {
    let device: MTLDevice

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available")
            throw SplatSorterTestError.noMetalDevice
        }
        self.device = device
    }

    @Test("sort single cloud returns correct splat count")
    func sortSingleCloudCount() throws {
        let cloud = try makeCloud(device: device, positions: [1, 2, 3, 4, 5])
        let params = SortParameters(camera: .identity, model: .identity)
        let indices = try SplatSorter.sort(device: device, splatCloud: cloud, parameters: params)
        #expect(indices.indices.count == 5)
    }

    @Test("sort multiple clouds returns combined splat count")
    func sortMultipleCloudsCount() throws {
        let cloudA = try makeCloud(device: device, positions: [1, 2, 3])
        let cloudB = try makeCloud(device: device, positions: [4, 5, 6, 7])
        let params = SortParameters(camera: .identity, model: .identity)
        let indices = try SplatSorter.sort(device: device, splatClouds: [cloudA, cloudB], parameters: params)
        #expect(indices.indices.count == 7)
    }

    @Test("sort empty clouds list returns zero indices")
    func sortEmptyClouds() throws {
        let params = SortParameters(camera: .identity, model: .identity)
        let indices = try SplatSorter.sort(device: device, splatClouds: [GPUSplatCloud<SparkSplat>](), parameters: params)
        #expect(indices.indices.count == 0)
    }

    @Test("sort preserves parameters in result")
    func sortPreservesParameters() throws {
        let cloud = try makeCloud(device: device, positions: [0, 1, 2])
        let params = SortParameters(camera: .identity, model: .identity, reversed: true)
        let indices = try SplatSorter.sort(device: device, splatCloud: cloud, parameters: params)
        #expect(indices.parameters.reversed == true)
    }

    @Test("sort single cloud applies modelTransform")
    func sortSingleCloudAppliesModelTransform() throws {
        // The sort shouldn't crash when the cloud has a non-identity modelTransform
        var transform = simd_float4x4.identity
        transform.columns.3 = SIMD4<Float>(10, 0, 0, 1)
        let cloud = try makeCloud(device: device, positions: [0, 1, 2])
        let cloudWithTransform = GPUSplatCloud<SparkSplat>(splats: cloud.splats, modelTransform: transform)
        let params = SortParameters(camera: .identity, model: .identity)
        let indices = try SplatSorter.sort(device: device, splatCloud: cloudWithTransform, parameters: params)
        #expect(indices.indices.count == 3)
    }
}

// MARK: -

private enum SplatSorterTestError: Error {
    case noMetalDevice
}
#endif
