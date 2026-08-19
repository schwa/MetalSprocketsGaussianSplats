#if !arch(x86_64)

@preconcurrency import ArgumentParser
import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

/// Frame-time scaling benchmark across renderers and splat counts.
///
/// The clouds are generated with a seed, so no large fixture files are needed.
/// To benchmark a real file, pass `--splat`. Run in Release. Debug numbers are
/// not representative, above all for the CPU sort.
struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Benchmark splat renderers across scene sizes"
    )

    enum BenchRenderer: String, ExpressibleByArgument, CaseIterable {
        case point
        case spark
        case gpu
        case tile
        case stochastic
    }

    @Option(help: "Comma-separated splat counts for synthetic clouds")
    var counts: String = "100000,500000,1000000,4000000,8000000"

    @Option(help: "Comma-separated target cull percentages for --sort-detail; the camera is rotated to frustum-cull ~that fraction (e.g. 0,25,50,75)")
    var cull: String = "0,10,20,50,100"

    @Option(help: "Renderers to benchmark (point, spark, gpu, tile, stochastic)")
    var renderers: [BenchRenderer] = [.point, .spark, .gpu]

    // Named --iterations, not --frames, so it does not collide with the root
    // command's --frames option.
    @Option(name: .customLong("iterations"), help: "Frames per measurement (median reported)")
    var frames: Int = 50

    @Option(help: "Render size (square)")
    var size: Int = 1_024

    @Option(help: "Benchmark a splat file instead of synthetic clouds")
    var splat: String?

    @Option(help: "Write results as CSV to this path")
    var csv: String?

    @Option(help: "PointSplat supersampling factor S")
    var supersampling: Int = 2

    @Option(help: "PointSplat points per thread K")
    var pointsPerThread: Int = 4

    @Flag(help: "Use quantized 18-byte packed splat storage for the point renderer (issue #77)")
    var packed = false

    @Flag(help: "Sweep PointSplat S/K configs for single-frame PSNR vs a converged reference (ignores --renderers)")
    var pointQuality = false

    @Option(help: "Accumulated frames for the converged PSNR reference")
    var referenceFrames: Int = 512

    @Flag(help: "Emit detailed per-pass GPU-sort spark timings (sort/render/vertex/fragment/total/submit) across sizes as JSON; ignores --renderers")
    var sortDetail = false

    struct BenchError: Error {
        var message: String
    }

    mutating func run() async throws {
        let frames = self.frames
        let size = self.size
        let renderers = self.renderers
        let splat = self.splat
        let csv = self.csv
        let countList = try counts.split(separator: ",").map { part in
            guard let value = Int(part.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")) else {
                throw BenchError(message: "Invalid count: \(part)")
            }
            return value
        }
        let supersampling = self.supersampling
        let pointsPerThread = self.pointsPerThread
        let packed = self.packed
        try await MainActor.run {
            var runner = try BenchRunner(size: size, frames: frames, supersampling: supersampling, pointsPerThread: pointsPerThread, packed: packed)
            var rows: [BenchRunner.Row] = []
            #if DEBUG
            FileHandle.standardError.write(Data("warning: Debug build; numbers will not be representative\n".utf8))
            #endif
            if pointQuality {
                if let splat {
                    let splats = try BenchRunner.loadSplats(url: URL(fileURLWithPath: splat))
                    try runner.pointQualitySweep(label: URL(fileURLWithPath: splat).lastPathComponent, splats: splats, referenceFrames: referenceFrames)
                } else {
                    for count in countList {
                        let splats = BenchRunner.syntheticCloud(count: count)
                        try runner.pointQualitySweep(label: count.formatted(.number.grouping(.never)), splats: splats, referenceFrames: referenceFrames)
                    }
                }
                return
            }
            if sortDetail {
                let cullList = try cull.split(separator: ",").map { part -> Double in
                    guard let value = Double(part.trimmingCharacters(in: .whitespaces)) else {
                        throw BenchError(message: "Invalid cull percentage: \(part)")
                    }
                    return value
                }
                var detail: [BenchRunner.SortDetailRow] = []
                if let splat {
                    let splats = try BenchRunner.loadSplats(url: URL(fileURLWithPath: splat))
                    let name = URL(fileURLWithPath: splat).lastPathComponent
                    for cullPercent in cullList {
                        detail.append(try runner.sortDetail(label: name, splats: splats, targetCull: cullPercent))
                    }
                } else {
                    for count in countList {
                        let splats = BenchRunner.syntheticCloud(count: count)
                        let name = count.formatted(.number.grouping(.never))
                        for cullPercent in cullList {
                            detail.append(try runner.sortDetail(label: name, splats: splats, targetCull: cullPercent))
                        }
                    }
                }
                try BenchRunner.printSortDetailJSON(detail, size: size, frames: frames)
                return
            }
            if let splat {
                let splats = try BenchRunner.loadSplats(url: URL(fileURLWithPath: splat))
                rows += try runner.benchmark(label: URL(fileURLWithPath: splat).lastPathComponent, splats: splats, renderers: renderers)
            } else {
                for count in countList {
                    let splats = BenchRunner.syntheticCloud(count: count)
                    rows += try runner.benchmark(label: count.formatted(.number.grouping(.never)), splats: splats, renderers: renderers)
                }
            }
            BenchRunner.printTable(rows)
            if let csv {
                try BenchRunner.writeCSV(rows, to: URL(fileURLWithPath: csv))
            }
        }
    }
}

@MainActor
struct BenchRunner {
    struct Row {
        var label: String
        var splatCount: Int
        var renderer: String
        var medianMS: Double
        var p10MS: Double
        var p90MS: Double
    }

    let size: Int
    let frames: Int
    let supersampling: Int
    let pointsPerThread: Int
    let device: MTLDevice
    let runner: Runner
    let packed: Bool

    init(size: Int, frames: Int, supersampling: Int = 2, pointsPerThread: Int = 4, packed: Bool = false) throws {
        self.packed = packed
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BenchCommand.BenchError(message: "No Metal device")
        }
        self.device = device
        self.runner = try Runner(device: device)
        self.size = size
        self.frames = frames
        self.supersampling = supersampling
        self.pointsPerThread = pointsPerThread
    }

    // MARK: - Cloud generation / loading

    /// Makes a random ball of splats. The positions are uniform in a unit
    /// sphere. The scales are log-normal. The orientation and color are random,
    /// and the alphas are mostly opaque. A seed makes the runs comparable.
    static func syntheticCloud(count: Int) -> [SparkSplat] {
        var generator = SplitMix64(seed: 0x5EED)
        var splats = [SparkSplat]()
        splats.reserveCapacity(count)
        for _ in 0..<count {
            // Rejection sampling keeps the point uniform in the ball.
            var position: SIMD3<Float>
            repeat {
                position = SIMD3<Float>(Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator))
            } while simd_length_squared(position) > 1.0
            let scale = exp(Float.random(in: -7.0..<(-4.5), using: &generator))
            let axis = simd_normalize(SIMD3<Float>(Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator), Float.random(in: -1...1, using: &generator)))
            let angle = Float.random(in: 0..<(2 * .pi), using: &generator)
            let quaternion = simd_quatf(angle: angle, axis: axis)
            let color = SIMD3<Float>(position.x * 0.5 + 0.5, position.y * 0.5 + 0.5, position.z * 0.5 + 0.5)
            splats.append(SparkSplat(
                position: simd_half3(Float16(position.x), Float16(position.y), Float16(position.z)),
                scale: simd_half3(Float16(scale), Float16(scale), Float16(scale)),
                rotation: simd_half4(Float16(quaternion.imag.x), Float16(quaternion.imag.y), Float16(quaternion.imag.z), Float16(quaternion.real)),
                color: simd_uchar4(UInt8(color.x * 255), UInt8(color.y * 255), UInt8(color.z * 255), UInt8.random(in: 200...255, using: &generator))
            ))
        }
        return splats
    }

    static func loadSplats(url: URL) throws -> [SparkSplat] {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BenchCommand.BenchError(message: "No Metal device")
        }
        return Array(try SplatLoader.read(device: device, url: url).splats)
    }

    // MARK: - Benchmarks

    mutating func benchmark(label: String, splats: [SparkSplat], renderers: [BenchCommand.BenchRenderer]) throws -> [Row] {
        let cameraMatrix = LookAt(position: SIMD3<Float>(0, 0, 2.5), target: .zero, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100))
        let projectionMatrix = projection.projectionMatrix(for: CGSize(width: size, height: size))

        var rows: [Row] = []
        for renderer in renderers {
            let times: [Double]
            do {
                switch renderer {
                case .point:
                    times = try benchmarkPointSplat(splats: splats, cameraMatrix: cameraMatrix, projectionMatrix: projectionMatrix)

                case .spark:
                    times = try benchmarkSpark(splats: splats, cameraMatrix: cameraMatrix, projectionMatrix: projectionMatrix)

                case .gpu:
                    times = try benchmarkGPUSort(splats: splats, cameraMatrix: cameraMatrix, projectionMatrix: projectionMatrix)

                case .tile:
                    times = try benchmarkTile(splats: splats, cameraMatrix: cameraMatrix, projection: projection)

                case .stochastic:
                    times = try benchmarkStochastic(splats: splats, cameraMatrix: cameraMatrix, projectionMatrix: projectionMatrix)
                }
            } catch {
                FileHandle.standardError.write(Data("  \(label) \(renderer.rawValue): failed (\(error))\n".utf8))
                continue
            }
            let sorted = times.sorted()
            let row = Row(
                label: label,
                splatCount: splats.count,
                renderer: renderer.rawValue,
                medianMS: sorted[sorted.count / 2] * 1_000,
                p10MS: sorted[sorted.count / 10] * 1_000,
                p90MS: sorted[min(sorted.count - 1, sorted.count * 9 / 10)] * 1_000
            )
            rows.append(row)
            // Progress goes to stderr so stdout stays a single clean CSV table.
            FileHandle.standardError.write(Data("  \(label) \(renderer.rawValue): \(row.medianMS.formatted(.number.precision(.fractionLength(2)))) ms\n".utf8))
        }
        return rows
    }

    private func benchmarkPointSplat(splats: [SparkSplat], cameraMatrix: simd_float4x4, projectionMatrix: simd_float4x4) throws -> [Double] {
        let renderer = try BenchPointSplatRenderer(device: device, runner: runner, size: size, supersampling: supersampling, pointsPerThread: pointsPerThread)
        if packed {
            let cloud = try PackedSplatCloud(device: device, splats: splats)
            return try measure { frame in
                _ = try renderer.render(splats: cloud.buffer, splatCount: cloud.count, packedBounds: cloud.bounds, viewMatrix: cameraMatrix.inverse, projectionMatrix: projectionMatrix, frameSeed: UInt32(frame))
            }
        }
        guard let buffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SparkSplat>.stride * splats.count) else {
            throw BenchCommand.BenchError(message: "Buffer allocation failed")
        }
        buffer.label = "Bench splats"
        return try measure { frame in
            _ = try renderer.render(splats: buffer, splatCount: splats.count, viewMatrix: cameraMatrix.inverse, projectionMatrix: projectionMatrix, frameSeed: UInt32(frame))
        }
    }

    private func benchmarkSpark(splats: [SparkSplat], cameraMatrix: simd_float4x4, projectionMatrix: simd_float4x4) throws -> [Double] {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let offscreen = try OffscreenRenderer(size: CGSize(width: size, height: size))
        let drawableSize = SIMD2<Float>(Float(size), Float(size))
        // The sort runs every frame. Interactive use resorts on camera motion,
        // and that cost is the point of the comparison.
        return try measure { _ in
            let sortedIndices = try SplatSorter.sort(device: device, splatCloud: cloud, parameters: SortParameters(camera: cameraMatrix, model: .identity))
            let renderPass = try RenderPass {
                try SparkSplatRenderPipeline(splatCloud: cloud, projectionMatrix: projectionMatrix, modelMatrix: .identity, cameraMatrix: cameraMatrix, drawableSize: drawableSize, sortedIndices: sortedIndices)
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.renderTargetArrayLength = 1
            }
            _ = try offscreen.render(renderPass)
        }
    }

    private func benchmarkGPUSort(splats: [SparkSplat], cameraMatrix: simd_float4x4, projectionMatrix: simd_float4x4) throws -> [Double] {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let resources = try GPUSortResources(device: device, capacity: cloud.count)
        let offscreen = try OffscreenRenderer(size: CGSize(width: size, height: size))
        let drawableSize = SIMD2<Float>(Float(size), Float(size))
        return try measure { _ in
            let pipeline = try GPUSortedSplatRenderPipeline(splatCloud: cloud, projectionMatrix: projectionMatrix, modelMatrix: .identity, cameraMatrix: cameraMatrix, drawableSize: drawableSize, resources: resources)
            _ = try offscreen.render(pipeline)
        }
    }

    private func benchmarkTile(splats: [SparkSplat], cameraMatrix: simd_float4x4, projection: PerspectiveProjection) throws -> [Double] {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let offscreen = try OffscreenRenderer(size: CGSize(width: size, height: size))
        let drawableSize = SIMD2<Float>(Float(size), Float(size))
        return try measure { _ in
            let pass = try TileBasedSplatPass(splatCloud: cloud, projection: projection, drawableSize: drawableSize, cameraMatrix: cameraMatrix, modelMatrix: .identity)
            _ = try offscreen.render(pass)
        }
    }

    private func benchmarkStochastic(splats: [SparkSplat], cameraMatrix: simd_float4x4, projectionMatrix: simd_float4x4) throws -> [Double] {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let offscreen = try OffscreenRenderer(size: CGSize(width: size, height: size))
        let drawableSize = SIMD2<Float>(Float(size), Float(size))
        // One stochastic frame per measurement, with no temporal accumulation.
        // This is the per-frame cost an interactive session pays.
        return try measure { frame in
            let renderPass = try RenderPass {
                try StochasticSplatRenderPipeline(splatCloud: cloud, projectionMatrix: projectionMatrix, modelMatrix: .identity, cameraMatrix: cameraMatrix, drawableSize: drawableSize, frameTime: UInt32(frame))
                    .depthCompare(function: .less, enabled: true)
            }
            .renderPassDescriptorModifier { descriptor in
                descriptor.renderTargetArrayLength = 1
            }
            _ = try offscreen.render(renderPass)
        }
    }

    /// Measures the wall-clock time per frame. Every renderer blocks until the
    /// GPU completes, so this approximates the frame cost. It discards two
    /// warmup frames.
    private func measure(_ body: (Int) throws -> Void) throws -> [Double] {
        try body(0)
        try body(1)
        var times: [Double] = []
        times.reserveCapacity(frames)
        for frame in 0..<frames {
            let start = ContinuousClock.now
            try body(frame + 2)
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
        }
        return times
    }

    // MARK: - PointSplat quality sweep

    /// Measures single-frame PSNR for each (S, K) configuration against a
    /// converged reference. The reference is the mean of many stochastic frames
    /// at the default S = 2, K = 4. This complements the timing sweep for the
    /// choice of defaults.
    func pointQualitySweep(label: String, splats: [SparkSplat], referenceFrames: Int) throws {
        let cameraMatrix = LookAt(position: SIMD3<Float>(0, 0, 2.5), target: .zero, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100))
        let projectionMatrix = projection.projectionMatrix(for: CGSize(width: size, height: size))
        guard let buffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SparkSplat>.stride * splats.count) else {
            throw BenchCommand.BenchError(message: "Buffer allocation failed")
        }
        buffer.label = "Bench splats"

        func frames(supersampling: Int, pointsPerThread: Int, count: Int, seedBase: UInt32) throws -> [[Float]] {
            let renderer = try BenchPointSplatRenderer(device: device, runner: runner, size: size, supersampling: supersampling, pointsPerThread: pointsPerThread)
            var result: [[Float]] = []
            for frame in 0..<count {
                let texture = try renderer.render(splats: buffer, splatCount: splats.count, viewMatrix: cameraMatrix.inverse, projectionMatrix: projectionMatrix, frameSeed: seedBase &+ UInt32(frame))
                result.append(try readRGB(texture))
            }
            return result
        }

        print("\(label): accumulating \(referenceFrames)-frame reference (S=2, K=4)...")
        var reference = [Double](repeating: 0, count: size * size * 3)
        for frame in try frames(supersampling: 2, pointsPerThread: 4, count: referenceFrames, seedBase: 0) {
            for index in reference.indices {
                reference[index] += Double(frame[index])
            }
        }
        for index in reference.indices {
            reference[index] /= Double(referenceFrames)
        }

        let configs = [(1, 1), (1, 4), (2, 1), (2, 4), (2, 8), (2, 16), (4, 4), (4, 16)]
        let evaluationFrames = 8
        print("")
        print("config  psnr_db")
        for (supersampling, pointsPerThread) in configs {
            let samples = try frames(supersampling: supersampling, pointsPerThread: pointsPerThread, count: evaluationFrames, seedBase: 10_000)
            var psnrSum = 0.0
            for sample in samples {
                var mse = 0.0
                for index in reference.indices {
                    let difference = Double(sample[index]) - reference[index]
                    mse += difference * difference
                }
                mse /= Double(reference.count)
                psnrSum += 10.0 * log10(1.0 / max(mse, 1e-12))
            }
            let configColumn = "S\(supersampling)K\(pointsPerThread)".padding(toLength: 7, withPad: " ", startingAt: 0)
            print("\(configColumn) \((psnrSum / Double(samples.count)).formatted(.number.precision(.fractionLength(2))))")
        }
    }

    /// Reads back RGB from an rgba32Float texture and drops the alpha.
    private func readRGB(_ texture: MTLTexture) throws -> [Float] {
        let pixelCount = texture.width * texture.height
        var rgba = [Float](repeating: 0, count: pixelCount * 4)
        if texture.storageMode == .managed {
            try runner.run(
                BlitPass {
                    Blit { encoder in
                        encoder.synchronize(resource: texture)
                    }
                }
            )
        }
        rgba.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return
            }
            texture.getBytes(baseAddress, bytesPerRow: texture.width * 16, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        var rgb = [Float](repeating: 0, count: pixelCount * 3)
        for pixel in 0..<pixelCount {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return rgb
    }

    // MARK: - GPU sort detail

    /// Detailed per-pass timings for the GPU-sort spark renderer at one size
    /// and one target cull fraction.
    struct SortDetailRow: Codable {
        var label: String
        var splats: Int
        var targetCullPercent: Double
        var actualCullPercent: Double?
        var visibleSplats: Int?
        var culledSplats: Int?
        var wall: Stat
        var sortGpu: Stat?
        var renderGpu: Stat?
        var vertex: Stat?
        var fragment: Stat?
        var gpuTotal: Stat?
        var commandBufferGpu: Stat?
    }

    private static let sortDetailProjection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100))

    /// Returns a camera-to-world matrix at distance 2.5 from the origin. The
    /// forward direction rotates by `theta` about Y. At theta=0 the camera
    /// looks at the cloud and culls the least. A larger theta rotates the cloud
    /// out of the frustum and culls more.
    private func cullCamera(theta: Float) -> simd_float4x4 {
        simd_float4x4(translation: SIMD3<Float>(0, 0, 2.5)) * simd_float4x4(simd_quatf(angle: theta, axis: SIMD3<Float>(0, 1, 0)))
    }

    @MainActor
    private func makeSortRenderer(cloud: GPUSplatCloud<SparkSplat>, camera: simd_float4x4) throws -> OffscreenSplatRenderer {
        try OffscreenSplatRenderer(
            renderer: .spark(sort: .gpu),
            splatCloud: cloud,
            projection: Self.sortDetailProjection,
            cameraMatrix: camera,
            configuration: .init(width: size, height: size, collectGPUCounters: true)
        )
    }

    /// Returns the culled fraction (0..100) for one camera, from the survivor
    /// count of the GPU sort.
    @MainActor
    private func probeCull(cloud: GPUSplatCloud<SparkSplat>, count: Int, theta: Float) throws -> Double {
        let report = try makeSortRenderer(cloud: cloud, camera: cullCamera(theta: theta)).renderFrame()
        guard let visible = report.visibleSplats, count > 0 else {
            return 0
        }
        return (1 - Double(visible) / Double(count)) * 100
    }

    /// Measures the GPU-sort spark renderer through OffscreenSplatRenderer with
    /// GPU counters. The camera rotates to cull ~targetCull%. This aggregates
    /// the per-pass FrameReport into a detail row.
    @MainActor
    func sortDetail(label: String, splats: [SparkSplat], targetCull: Double) throws -> SortDetailRow {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let count = splats.count

        // The culled fraction rises monotonically with theta over [0, pi], so a
        // binary search finds the camera rotation for ~targetCull%.
        var theta: Float = 0
        if targetCull > 0 {
            var lo: Float = 0, hi: Float = .pi
            for _ in 0..<14 {
                let mid = (lo + hi) / 2
                let culled = try probeCull(cloud: cloud, count: count, theta: mid)
                if culled < targetCull { lo = mid } else { hi = mid }
            }
            theta = (lo + hi) / 2
        }

        let renderer = try makeSortRenderer(cloud: cloud, camera: cullCamera(theta: theta))
        for _ in 0..<2 { _ = try renderer.renderFrame() }   // warmup
        var wall: [Double] = [], sortGpu: [Double] = [], renderGpu: [Double] = []
        var vertex: [Double] = [], fragment: [Double] = [], total: [Double] = [], submit: [Double] = []
        var lastVisible: Int?
        for _ in 0..<frames {
            let start = ContinuousClock.now
            let report = try renderer.renderFrame()
            wall.append(elapsedSeconds(since: start))
            if let value = report.sortGPU?.duration { sortGpu.append(value) }
            if let value = report.render?.duration { renderGpu.append(value) }
            if let value = report.render?.vertex?.duration { vertex.append(value) }
            if let value = report.render?.fragment?.duration { fragment.append(value) }
            if let value = report.render?.duration { total.append((report.sortGPU?.duration ?? 0) + value) }
            if let value = report.commandBufferGPUTime { submit.append(value) }
            lastVisible = report.visibleSplats ?? lastVisible
        }
        func s(_ values: [Double]) -> Stat? { values.isEmpty ? nil : stat(values) }
        let actualCull = lastVisible.map { count > 0 ? (1 - Double($0) / Double(count)) * 100 : 0 }
        return SortDetailRow(
            label: label,
            splats: count,
            targetCullPercent: targetCull,
            actualCullPercent: actualCull,
            visibleSplats: lastVisible,
            culledSplats: lastVisible.map { max(0, count - $0) },
            wall: stat(wall),
            sortGpu: s(sortGpu),
            renderGpu: s(renderGpu),
            vertex: s(vertex),
            fragment: s(fragment),
            gpuTotal: s(total),
            commandBufferGpu: s(submit)
        )
    }

    static func printSortDetailJSON(_ rows: [SortDetailRow], size: Int, frames: Int) throws {
        struct Report: Codable { var size: Int; var frames: Int; var rows: [SortDetailRow] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Report(size: size, frames: frames, rows: rows))
        print(String(bytes: data, encoding: .utf8) ?? "")
    }

    // MARK: - Output

    /// Returns CSV lines: a header and one row per measurement. Both stdout and
    /// the `--csv` file use this, so they are identical.
    static func csvLines(_ rows: [Row]) -> [String] {
        var lines = ["label,splats,renderer,median_ms,p10_ms,p90_ms"]
        for row in rows {
            lines.append("\(row.label),\(row.splatCount),\(row.renderer),\(row.medianMS),\(row.p10MS),\(row.p90MS)")
        }
        return lines
    }

    static func printTable(_ rows: [Row]) {
        print(csvLines(rows).joined(separator: "\n"))
    }

    static func writeCSV(_ rows: [Row], to url: URL) throws {
        try csvLines(rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Bench-local blocking wrapper around ``PointSplatComputePass``. It renders one
/// stochastic frame per call into a float texture.
private final class BenchPointSplatRenderer {
    private let runner: Runner
    private let texture: MTLTexture
    private let supersampling: Int
    private let pointsPerThread: Int
    /// Monotonic plan key. The frame seeds can repeat across measurements.
    private var planCounter: UInt64 = 0

    init(device: MTLDevice, runner: Runner, size: Int, supersampling: Int, pointsPerThread: Int) throws {
        self.runner = runner
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BenchCommand.BenchError(message: "Texture allocation failed")
        }
        texture.label = "PointSplat resolve"
        self.texture = texture
        self.supersampling = supersampling
        self.pointsPerThread = pointsPerThread
    }

    func render(splats: MTLBuffer, splatCount: Int, packedBounds: GPSPackedSplatBounds? = nil, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, frameSeed: UInt32) throws -> MTLTexture {
        planCounter += 1
        let pass = PointSplatComputePass(
            splats: splats,
            splatCount: splatCount,
            packedBounds: packedBounds,
            modelMatrix: .identity,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            frameSeed: frameSeed,
            planKey: planCounter,
            outTexture: texture,
            supersampling: supersampling,
            pointsPerThread: pointsPerThread
        )
        try runner.run(pass)
        return texture
    }
}

/// Seeded RNG so the synthetic clouds are identical across runs.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

#endif
