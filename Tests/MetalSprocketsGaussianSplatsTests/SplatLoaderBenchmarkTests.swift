#if !arch(x86_64)
import Foundation
import Metal
@testable import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
@testable import Splats
import Testing

/// Load-time benchmark for every supported format through the production loader.
///
/// `SplatLoader` reads PLY, SPZ v3, SPZ v4 (CPU decode to buffer), and SOG (GPU
/// compute decode). The test reports median and min ms and MB/s per file. CI
/// skips it because it measures timing. It also writes the table to a temp
/// file, because the runner swallows stdout. Large clouds come from
/// `just bench` (Tests/SplatsTests/Fixtures/Bench).
@Suite("SplatLoaderBenchmark", .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "Timing benchmark"))
struct SplatLoaderBenchmarkTests {
    private let warmup = 1
    private let iterations = Int(ProcessInfo.processInfo.environment["SPLAT_BENCHMARK_ITERATIONS"] ?? "5") ?? 5

    @Test(.enabled(if: MetalTestSupport.supports64BitAtomics))
    func benchmarkAllFormats() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())

        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        func f(_ v: Double, _ d: Int) -> String { String(format: "%.\(d)f", v) }

        var rows = [pad("file", 22) + pad("splats", 10) + pad("MB", 9) + pad("med ms", 10) + pad("min ms", 9) + pad("MB/s", 8)]
        for url in benchmarkFiles() {
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            let mb = Double(size) / 1_000_000

            var count = 0
            do {
                let times = try measure {
                    let result = try SplatLoader.read(device: device, url: url)
                    count = result.count
                }
                #expect(count > 0, "\(url.lastPathComponent) decoded no splats")
                let med = median(times), mn = times.min() ?? 0
                let mbps = med > 0 ? mb / med : 0
                rows.append(pad(url.lastPathComponent, 22) + pad("\(count)", 10) + pad(f(mb, 2), 9)
                    + pad(f(med * 1_000, 2), 10) + pad(f(mn * 1_000, 2), 9) + pad(f(mbps, 0), 8))
            } catch {
                rows.append(pad(url.lastPathComponent, 22) + "  FAILED: \(error)")
                Issue.record("\(url.lastPathComponent) failed to load: \(error)")
            }
        }

        let table = "Splat load benchmark (SplatLoader) — median of \(iterations) (\(warmup) warmup)\n" + rows.joined(separator: "\n")
        print(table)
        try? table.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("splat-load-benchmark.txt"), atomically: true, encoding: .utf8)
    }

    /// Bundled small fixtures plus the large synthetic clouds from `just bench`
    /// (in the SplatsTests fixtures dir). Missing files are skipped.
    private func benchmarkFiles() -> [URL] {
        if let paths = ProcessInfo.processInfo.environment["SPLAT_BENCHMARK_FILES"] {
            return paths.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        var urls: [URL] = []
        for (name, ext) in [("test-grid", "ply"), ("test-grid", "spz")] {
            if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
                urls.append(url)
            }
        }
        let bench = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SplatsTests/Fixtures/Bench")
        for name in ["bench-grid.ply", "bench-grid.sog", "bench-grid.v3.spz", "bench-grid.v4.spz"] {
            let url = bench.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                urls.append(url)
            }
        }
        return urls
    }

    private func measure(_ body: () throws -> Void) rethrows -> [TimeInterval] {
        for _ in 0..<warmup { try body() }
        var times: [TimeInterval] = []
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            try body()
            let e = ContinuousClock.now - start
            times.append(Double(e.components.seconds) + Double(e.components.attoseconds) * 1e-18)
        }
        return times
    }

    private func median(_ v: [TimeInterval]) -> TimeInterval { v.sorted()[v.count / 2] }
}
#endif
