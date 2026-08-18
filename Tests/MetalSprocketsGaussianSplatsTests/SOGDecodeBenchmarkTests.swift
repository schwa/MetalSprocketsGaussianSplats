#if !arch(x86_64)
import Foundation
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
@testable import Splats
import Testing

/// One-off comparison: SOG decode via the CPU reader (`SOGReaderCPU` streaming
/// into `[SparkSplat]`) vs the GPU reader (`SOGReaderGPU` compute kernel).
/// CI-skipped (timing). Dumps the table to a temp file since runner stdout is
/// swallowed.
@Suite("SOGDecodeBenchmark", .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Timing benchmark"))
struct SOGDecodeBenchmarkTests {
    private let warmup = 1
    private let iterations = 5

    @Test(.enabled(if: MetalTestSupport.supports64BitAtomics))
    func compareCPUvsGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())

        var rows = ["file                    splats   cpu med   cpu min   gpu med   gpu min   speedup"]
        for url in sogFiles() {
            let cpu = try measure {
                let reader = try SOGReaderCPU(url: url)
                var splats: [SparkSplat] = []
                splats.reserveCapacity(reader.splatCount)
                var sh: [Float] = []
                try reader.read { _, e in
                    splats.append(SparkSplat(e.genericSplat))
                    if let coeffs = e.sphericalHarmonics { for c in coeffs { sh.append(contentsOf: c) } }
                }
                return splats.count
            }
            let gpu = try measure {
                try SOGReaderGPU(device: device).read(url: url).count
            }
            let cpuMed = median(cpu.times), gpuMed = median(gpu.times)
            #expect(cpu.value == gpu.value, "\(url.lastPathComponent): CPU/GPU splat counts differ")

            func ms(_ v: Double) -> String { String(format: "%.1f", v * 1_000) }
            let speedup = gpuMed > 0 ? cpuMed / gpuMed : 0
            rows.append("\(pad(url.lastPathComponent, 20)) \(pad("\(cpu.value)", 8)) "
                + "\(pad(ms(cpuMed), 8)) \(pad(ms(cpu.times.min() ?? 0), 8)) "
                + "\(pad(ms(gpuMed), 8)) \(pad(ms(gpu.times.min() ?? 0), 8)) \(pad(String(format: "%.1fx", speedup), 8))")
        }

        let table = "SOG decode: CPU vs GPU (ms, median of \(iterations), \(warmup) warmup)\n" + rows.joined(separator: "\n")
        print(table)
        try? table.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("sog-decode-benchmark.txt"), atomically: true, encoding: .utf8)
    }

    private func sogFiles() -> [URL] {
        var urls: [URL] = []
        if let ring = Bundle.module.url(forResource: "test-ring", withExtension: "sog", subdirectory: "Fixtures") {
            urls.append(ring)
        }
        // Large synthetic cloud from `just bench` (Tests/SplatsTests/Fixtures/Bench).
        let bench = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SplatsTests/Fixtures/Bench/bench-grid.sog")
        if FileManager.default.fileExists(atPath: bench.path) {
            urls.append(bench)
        }
        return urls
    }

    private func measure<T>(_ body: () throws -> T) rethrows -> (value: T, times: [TimeInterval]) {
        var value = try body()
        for _ in 1..<warmup + 1 { value = try body() }
        var times: [TimeInterval] = []
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            value = try body()
            let e = ContinuousClock.now - start
            times.append(Double(e.components.seconds) + Double(e.components.attoseconds) * 1e-18)
        }
        return (value, times)
    }

    private func median(_ v: [TimeInterval]) -> TimeInterval { v.sorted()[v.count / 2] }
    private func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
}
#endif
