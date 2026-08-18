#if !arch(x86_64)
import Foundation
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
@testable import Splats
import Testing

/// The unified buffer-producing reader API: `SplatReaderProtocol.read(device:)`,
/// the `SplatLoader` facade, and the `GPUSplatCloud(_:)` convenience init.
@Suite("SplatBufferReading")
struct SplatBufferReadingTests {
    @Test("CPU reader read(device:) matches the streamed splat/SH counts")
    func readDeviceMatchesStream() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try #require(Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures"))

        // Streamed reference.
        let reader = try SplatReader(url: url)
        var streamed = 0
        try reader.read { _, _ in streamed += 1 }

        let result = try SplatReader(url: url).read(device: device)
        #expect(result.count == streamed)
        #expect(result.splats.count == streamed)
        #expect(result.shDegree == reader.shDegree)

        // Cloud construction from the result.
        let cloud = GPUSplatCloud(result)
        #expect(cloud.count == streamed)
    }

    @Test("SplatLoader routes SOG through the GPU decoder", .enabled(if: MetalTestSupport.supports64BitAtomics))
    func loaderRoutesSOGToGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try #require(Bundle.module.url(forResource: "test-ring", withExtension: "sog", subdirectory: "Fixtures"))

        let viaLoader = try SplatLoader.read(device: device, url: url)
        let viaGPU = try SOGReaderGPU(device: device).read(url: url).bufferResult

        #expect(viaLoader.count == viaGPU.count)
        #expect(viaLoader.shDegree == viaGPU.shDegree)
        #expect(viaLoader.count > 0)
    }
}
#endif
