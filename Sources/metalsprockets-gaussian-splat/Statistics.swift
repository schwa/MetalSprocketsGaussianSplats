#if !arch(x86_64)

import ArgumentParser
import Foundation
import MetalSprockets

enum StatisticsFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
}

enum SortMethod: String, CaseIterable, ExpressibleByArgument {
    case cpu
    case gpu
}

enum RendererKind: String, CaseIterable, ExpressibleByArgument {
    case spark
    case point
    case tile
    case stochastic
}

/// Timings for one measured frame.
struct FrameSample {
    var wallTime: TimeInterval
    /// CPU radix sort wall time; absent when sorting on the GPU.
    var sortCPUTime: TimeInterval?
    /// GPU sort compute pass sample; absent when sorting on the CPU.
    var sortGPU: GPUCounterSample?
    var render: GPUCounterSample?
    /// Frustum-cull survivors; the GPU sort is the only path that culls.
    var visibleSplats: Int?
    /// Whole-submission GPU time from the command-buffer clock (correlation-free).
    var commandBufferGPUTime: TimeInterval?

    init(wallTime: TimeInterval, sortCPUTime: TimeInterval? = nil, sortGPU: GPUCounterSample? = nil, render: GPUCounterSample? = nil, visibleSplats: Int? = nil, commandBufferGPUTime: TimeInterval? = nil) {
        self.wallTime = wallTime
        self.sortCPUTime = sortCPUTime
        self.sortGPU = sortGPU
        self.render = render
        self.visibleSplats = visibleSplats
        self.commandBufferGPUTime = commandBufferGPUTime
    }
}

struct Stat: Codable {
    var medianMs: Double
    var minMs: Double
}

/// Summarizes a non-empty list of durations in seconds.
func stat(_ values: [Double]) -> Stat {
    let sorted = values.sorted()
    return Stat(medianMs: sorted[sorted.count / 2] * 1_000, minMs: (sorted.first ?? 0) * 1_000)
}

struct StatisticsReport: Codable {
    var splats: Int
    var shDegree: Int
    var width: Int
    var height: Int
    var frames: Int
    var warmup: Int
    var renderer: String
    /// Only meaningful for the spark renderer; the others do not sort.
    var sortMethod: String
    /// Frustum-cull survivors from the last measured frame (GPU sort only).
    var visibleSplats: Int?
    var culledSplats: Int?
    /// Sort plus render, per frame, CPU wall clock.
    var wall: Stat
    /// CPU radix sort wall time (--sort cpu only).
    var sortCpu: Stat?
    /// GPU sort compute pass time from timestamp counters (--sort gpu only).
    var sortGpu: Stat?
    /// Render pass GPU time from timestamp counters. Absent when the device
    /// does not support stage-boundary sampling.
    var renderGpu: Stat?
    /// Vertex and fragment stages overlap, so they do not sum to renderGpu.
    var vertex: Stat?
    var fragment: Stat?
    /// GPU sort + render per frame (summarized per frame, not a sum of the two
    /// summaries). Absent when render GPU timing is unavailable.
    var gpuTotal: Stat?
    /// Whole-submission GPU time from the command-buffer clock. Correlation-free,
    /// so a sanity cross-check on the counter-derived numbers (for GPU sort this
    /// spans sort+render in one submission).
    var commandBufferGpu: Stat?
}

func makeReport(samples: [FrameSample], splats: Int, shDegree: Int, width: Int, height: Int, warmup: Int, renderer: RendererKind, sortMethod: SortMethod) -> StatisticsReport {
    let sortCPUTimes = samples.compactMap(\.sortCPUTime)
    let sortGPUTimes = samples.compactMap { $0.sortGPU?.duration }
    let gpuTimes = samples.compactMap { $0.render?.duration }
    let vertexTimes = samples.compactMap { $0.render?.vertex?.duration }
    let fragmentTimes = samples.compactMap { $0.render?.fragment?.duration }
    let commandBufferGPUTimes = samples.compactMap(\.commandBufferGPUTime)
    // Per-frame GPU total: the fastest sort and fastest render need not occur on
    // the same frame, so sum per frame then summarize (not a sum of summaries).
    let gpuTotalTimes = samples.compactMap { sample -> Double? in
        guard let render = sample.render?.duration else { return nil }
        return (sample.sortGPU?.duration ?? 0) + render
    }
    let visible = samples.last?.visibleSplats
    return StatisticsReport(
        splats: splats,
        shDegree: shDegree,
        width: width,
        height: height,
        frames: samples.count,
        warmup: warmup,
        renderer: renderer.rawValue,
        sortMethod: sortMethod.rawValue,
        visibleSplats: visible,
        culledSplats: visible.map { max(0, splats - $0) },
        wall: stat(samples.map(\.wallTime)),
        sortCpu: sortCPUTimes.isEmpty ? nil : stat(sortCPUTimes),
        sortGpu: sortGPUTimes.isEmpty ? nil : stat(sortGPUTimes),
        renderGpu: gpuTimes.isEmpty ? nil : stat(gpuTimes),
        vertex: vertexTimes.isEmpty ? nil : stat(vertexTimes),
        fragment: fragmentTimes.isEmpty ? nil : stat(fragmentTimes),
        gpuTotal: gpuTotalTimes.isEmpty ? nil : stat(gpuTotalTimes),
        commandBufferGpu: commandBufferGPUTimes.isEmpty ? nil : stat(commandBufferGPUTimes)
    )
}

func emitReport(_ report: StatisticsReport, format: StatisticsFormat) throws {
    switch format {
    case .text:
        printTextReport(report)

    case .json:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(bytes: try encoder.encode(report), encoding: .utf8) ?? "")
    }
}

private func printTextReport(_ report: StatisticsReport) {
    print("")
    print("Statistics — median of \(report.frames) frame(s), \(report.warmup) warm-up")
    print("  scene       \(report.splats) splats, SH degree \(report.shDegree)")
    let sortSuffix = report.renderer == RendererKind.spark.rawValue ? " (\(report.sortMethod) sort)" : ""
    print("  renderer    \(report.renderer)\(sortSuffix)")
    print("  size        \(report.width)x\(report.height)")
    if let visible = report.visibleSplats, let culled = report.culledSplats {
        let percent = report.splats > 0 ? Double(culled) / Double(report.splats) * 100 : 0
        print(String(format: "  culling     %d visible, %d culled (%.1f%%)", visible, culled, percent))
    }
    line("wall", report.wall)
    if let sortCpu = report.sortCpu {
        line("cpu sort", sortCpu)
    }
    if let sortGpu = report.sortGpu {
        line("gpu sort", sortGpu)
    }
    if let renderGpu = report.renderGpu {
        line("gpu render", renderGpu)
    }
    if let vertex = report.vertex {
        line("  vertex", vertex)
    }
    if let fragment = report.fragment {
        line("  fragment", fragment)
    }
    if let gpuTotal = report.gpuTotal {
        line("gpu total", gpuTotal)
    }
    if let commandBufferGpu = report.commandBufferGpu {
        line("gpu submit", commandBufferGpu)
    }
}

private func line(_ label: String, _ stat: Stat) {
    let padding = String(repeating: " ", count: max(1, 12 - label.count))
    print(String(format: "  %@%@%.3f ms (min %.3f)", label, padding, stat.medianMs, stat.minMs))
}

func elapsedSeconds(since start: ContinuousClock.Instant) -> TimeInterval {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
}

#endif
