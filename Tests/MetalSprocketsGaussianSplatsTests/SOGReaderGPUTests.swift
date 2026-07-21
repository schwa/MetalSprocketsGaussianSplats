#if !arch(x86_64)
import Foundation
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
@testable import Splats
import Testing

/// Parity tests: the GPU decode path (`SOGReaderGPU`) must produce the same
/// splats and SH coefficients as the CPU path (`SOGReaderCPU`).
@Suite("SOGReaderGPU")
struct SOGReaderGPUTests {
    @Test("GPU decode matches CPU reference on test-ring.sog")
    func parityWithCPUReader() throws {
        let url = try #require(Bundle.module.url(forResource: "test-ring", withExtension: "sog", subdirectory: "Fixtures"))
        let device = try #require(MTLCreateSystemDefaultDevice())

        // CPU reference.
        let cpuReader = try SOGReaderCPU(url: url)
        var cpuSplats: [SparkSplat] = []
        var cpuSH: [Float] = []
        try cpuReader.read { _, extendedSplat in
            cpuSplats.append(SparkSplat(extendedSplat.genericSplat))
            if let sh = extendedSplat.sphericalHarmonics {
                for coefficient in sh {
                    cpuSH.append(contentsOf: coefficient)
                }
            }
        }

        // GPU path.
        let gpuResult = try SOGReaderGPU(device: device).load(url: url)
        #expect(gpuResult.count == cpuSplats.count)
        #expect(gpuResult.shDegree == cpuReader.shDegree)

        let gpuSplats = Array(gpuResult.splats)
        var maxPositionError: Float = 0
        var maxScaleError: Float = 0
        var maxColorError = 0
        for i in 0..<min(cpuSplats.count, gpuSplats.count) {
            let cpu = cpuSplats[i]
            let gpu = gpuSplats[i]
            maxPositionError = max(maxPositionError, simd_reduce_max(simd_abs(SIMD3<Float>(cpu.position) - SIMD3<Float>(gpu.position))))
            maxScaleError = max(maxScaleError, simd_reduce_max(simd_abs(SIMD3<Float>(cpu.scale) - SIMD3<Float>(gpu.scale))))
            for channel in 0..<4 {
                maxColorError = max(maxColorError, abs(Int(cpu.color[channel]) - Int(gpu.color[channel])))
            }
            // Quaternions: q and -q are the same rotation.
            let cpuRotation = SIMD4<Float>(cpu.rotation)
            let gpuRotation = SIMD4<Float>(gpu.rotation)
            let direct = simd_reduce_max(simd_abs(cpuRotation - gpuRotation))
            let negated = simd_reduce_max(simd_abs(cpuRotation + gpuRotation))
            #expect(min(direct, negated) < 2e-2, "rotation mismatch at splat \(i)")
        }
        #expect(maxPositionError < 2e-2, "max position error \(maxPositionError)")
        #expect(maxScaleError < 2e-2, "max scale error \(maxScaleError)")
        #expect(maxColorError <= 1, "max color error \(maxColorError)")

        // SH coefficients (if the fixture has them).
        let gpuSH = Array(gpuResult.shCoefficients)
        #expect(gpuSH.count == cpuSH.count)
        var maxSHError: Float = 0
        for i in 0..<min(cpuSH.count, gpuSH.count) {
            maxSHError = max(maxSHError, abs(cpuSH[i] - gpuSH[i]))
        }
        #expect(maxSHError < 2e-2, "max SH error \(maxSHError)")
    }
}
#endif
