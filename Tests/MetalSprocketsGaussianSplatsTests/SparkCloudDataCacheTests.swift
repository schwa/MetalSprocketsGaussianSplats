import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Testing

struct SparkCloudDataCacheTests {
    private func makeCache() throws -> (SparkSplatRenderPipeline.CloudDataCache, GPUSplatCloud<SparkSplat>) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: [SparkSplat()])
        let buffer = try device.makeTypedBuffer(values: [SplatCloudData()], options: [])
        let cache = SparkSplatRenderPipeline.CloudDataCache(modelMatrix: .identity, clouds: [cloud], buffer: buffer)
        return (cache, cloud)
    }

    @Test
    func cacheInvalidatesOnModelTransformChange() throws {
        let (cache, cloud) = try makeCache()
        #expect(cache.matches(clouds: [cloud], modelMatrix: .identity))
        cloud.modelTransform = simd_float4x4(translation: [1, 2, 3])
        #expect(!cache.matches(clouds: [cloud], modelMatrix: .identity))
    }

    @Test
    func cacheInvalidatesOnOpacityChange() throws {
        let (cache, cloud) = try makeCache()
        cloud.opacity = 0.5
        #expect(!cache.matches(clouds: [cloud], modelMatrix: .identity))
    }
}
