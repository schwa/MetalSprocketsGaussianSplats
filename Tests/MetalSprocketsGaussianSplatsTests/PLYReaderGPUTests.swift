#if !arch(x86_64)
import Foundation
import Metal
import MetalSprocketsGaussianSplatShaders
import simd
@testable import Splats
import Testing

@Suite("PLYReaderGPU")
struct PLYReaderGPUTests {
    @Test("GPU decode matches the CPU reference")
    func parityWithCPUReader() throws {
        let url = try #require(Bundle.module.url(forResource: "test-grid", withExtension: "ply", subdirectory: "Fixtures"))
        let device = try #require(MTLCreateSystemDefaultDevice())

        let cpuReader = try PLYSplatReader(url: url)
        var cpuSplats: [SparkSplat] = []
        var cpuSH: [Float] = []
        try cpuReader.read { _, extended in
            cpuSplats.append(SparkSplat(extended.genericSplat))
            extended.sphericalHarmonics?.forEach { cpuSH.append(contentsOf: $0) }
        }

        let gpu = try PLYReaderGPU(device: device).read(url: url)
        let gpuSplats = Array(gpu.splats)
        #expect(gpu.count == cpuSplats.count)
        #expect(gpu.shDegree == cpuReader.shDegree)

        for index in cpuSplats.indices {
            let cpu = cpuSplats[index]
            let decoded = gpuSplats[index]
            #expect(simd_reduce_max(simd_abs(SIMD3<Float>(cpu.position) - SIMD3<Float>(decoded.position))) < 2e-2)
            #expect(simd_reduce_max(simd_abs(SIMD3<Float>(cpu.scale) - SIMD3<Float>(decoded.scale))) < 2e-2)
            #expect(simd_reduce_max(simd_abs(SIMD4<Float>(cpu.rotation) - SIMD4<Float>(decoded.rotation))) < 2e-2)
            for channel in 0..<4 {
                #expect(abs(Int(cpu.color[channel]) - Int(decoded.color[channel])) <= 1)
            }
        }

        let gpuSH = Array(gpu.shCoefficients)
        #expect(gpuSH.count == cpuSH.count)
        for index in cpuSH.indices {
            #expect(abs(cpuSH[index] - gpuSH[index]) < 1e-5)
        }
    }
}
#endif
