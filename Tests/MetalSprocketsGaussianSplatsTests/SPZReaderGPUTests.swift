#if !arch(x86_64)
import Foundation
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
@testable import Splats
import Testing

/// Parity: the GPU SPZ unpack (`SPZReaderGPU`) must match the CPU reference
/// (`SPZReader` streaming into `SparkSplat`), which is still the device-free
/// decoder for SPZ.
@Suite("SPZReaderGPU")
struct SPZReaderGPUTests {
    @Test("GPU unpack matches the CPU reference on test-grid.spz")
    func parityWithCPUReader() throws {
        let url = try #require(Bundle.module.url(forResource: "test-grid", withExtension: "spz", subdirectory: "Fixtures"))
        let device = try #require(MTLCreateSystemDefaultDevice())

        // CPU reference.
        let cpuReader = try SPZReader(url: url)
        var cpuSplats: [SparkSplat] = []
        var cpuSH: [Float] = []
        try cpuReader.read { _, extended in
            cpuSplats.append(SparkSplat(extended.genericSplat))
            if let sh = extended.sphericalHarmonics {
                for coefficient in sh { cpuSH.append(contentsOf: coefficient) }
            }
        }

        // GPU path.
        let gpu = try SPZReaderGPU(device: device).read(url: url)
        #expect(gpu.count == cpuSplats.count)
        #expect(gpu.shDegree == cpuReader.shDegree)

        let gpuSplats = Array(gpu.splats)
        #expect(gpuSplats.count == cpuSplats.count)
        var maxPos: Float = 0, maxScale: Float = 0, maxColor = 0
        for i in 0..<min(cpuSplats.count, gpuSplats.count) {
            let cpu = cpuSplats[i], g = gpuSplats[i]
            maxPos = max(maxPos, simd_reduce_max(simd_abs(SIMD3<Float>(cpu.position) - SIMD3<Float>(g.position))))
            maxScale = max(maxScale, simd_reduce_max(simd_abs(SIMD3<Float>(cpu.scale) - SIMD3<Float>(g.scale))))
            for c in 0..<4 { maxColor = max(maxColor, abs(Int(cpu.color[c]) - Int(g.color[c]))) }
            // Quaternions: q and -q are the same rotation.
            let cq = SIMD4<Float>(cpu.rotation), gq = SIMD4<Float>(g.rotation)
            let d = min(simd_reduce_max(simd_abs(cq - gq)), simd_reduce_max(simd_abs(cq + gq)))
            #expect(d < 2e-2, "rotation mismatch at \(i)")
        }
        #expect(maxPos < 2e-2, "max position error \(maxPos)")
        #expect(maxScale < 2e-2, "max scale error \(maxScale)")
        #expect(maxColor <= 1, "max color error \(maxColor)")

        let gpuSH = Array(gpu.shCoefficients)
        #expect(gpuSH.count == cpuSH.count)
        var maxSH: Float = 0
        for i in 0..<min(cpuSH.count, gpuSH.count) {
            maxSH = max(maxSH, abs(cpuSH[i] - gpuSH[i]))
        }
        #expect(maxSH < 2e-2, "max SH error \(maxSH)")
    }
}
#endif
