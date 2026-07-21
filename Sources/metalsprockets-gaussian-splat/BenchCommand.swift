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
/// Clouds are generated procedurally (seeded), so no large fixture files are
/// needed; pass `--splat` to benchmark a real file instead. Run in Release —
/// Debug numbers are meaningless (especially the CPU sort).
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

    @Option(help: "Renderers to benchmark (point, spark, gpu, tile, stochastic)")
    var renderers: [BenchRenderer] = [.point, .spark, .gpu]

    @Option(help: "Frames per measurement (median reported)")
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
            print("warning: Debug build; numbers will not be representative")
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

    /// Random ball of splats: uniform positions in a unit sphere, log-normal
    /// scales, random orientation and color, mostly-opaque alphas. Seeded so
    /// runs are comparable.
    static func syntheticCloud(count: Int) -> [SparkSplat] {
        var generator = SplitMix64(seed: 0x5EED)
        var splats = [SparkSplat]()
        splats.reserveCapacity(count)
        for _ in 0..<count {
            // Uniform in ball via rejection.
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
        if url.pathExtension.lowercased() == "sog" {
            return Array(try SOGReaderGPU(device: device).read(url: url).splats)
        }
        let reader = try SplatReader(url: url)
        var splats: [SparkSplat] = []
        splats.reserveCapacity(reader.splatCount)
        try reader.read { _, extendedSplat in
            splats.append(SparkSplat(extendedSplat.genericSplat))
        }
        return splats
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
                print("\(label) \(renderer.rawValue): failed (\(error))")
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
            print("\(label) \(renderer.rawValue): median \(row.medianMS.formatted(.number.precision(.fractionLength(2)))) ms")
        }
        return rows
    }

    private func benchmarkPointSplat(splats: [SparkSplat], cameraMatrix: simd_float4x4, projectionMatrix: simd_float4x4) throws -> [Double] {
        let renderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size, supersampling: supersampling, pointsPerThread: pointsPerThread))
        if packed {
            let cloud = try PackedSplatCloud(device: device, splats: splats)
            return try measure { frame in
                _ = try renderer.render(packed: cloud, modelMatrix: .identity, viewMatrix: cameraMatrix.inverse, projectionMatrix: projectionMatrix, frameSeed: UInt32(frame))
            }
        }
        guard let buffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SparkSplat>.stride * splats.count) else {
            throw BenchCommand.BenchError(message: "Buffer allocation failed")
        }
        buffer.label = "Bench splats"
        return try measure { frame in
            _ = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: cameraMatrix.inverse, projectionMatrix: projectionMatrix, frameSeed: UInt32(frame))
        }
    }

    private func benchmarkSpark(splats: [SparkSplat], cameraMatrix: simd_float4x4, projectionMatrix: simd_float4x4) throws -> [Double] {
        let cloud = try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
        let offscreen = try OffscreenRenderer(size: CGSize(width: size, height: size))
        let drawableSize = SIMD2<Float>(Float(size), Float(size))
        // Sort every frame: interactive use resorts on camera motion, and
        // that cost is the point of the comparison.
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
        // Single stochastic frame per measurement, no temporal accumulation:
        // this is the per-frame cost an interactive session pays.
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

    /// Wall-clock per frame; every renderer blocks until GPU completion, so
    /// this approximates frame cost. Two warmup frames are discarded.
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

    /// Single-frame PSNR per (S, K) configuration against a converged
    /// reference (mean of many stochastic frames at the S = 2, K = 4
    /// default). Complements the timing sweep for picking defaults.
    func pointQualitySweep(label: String, splats: [SparkSplat], referenceFrames: Int) throws {
        let cameraMatrix = LookAt(position: SIMD3<Float>(0, 0, 2.5), target: .zero, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 0.01...100))
        let projectionMatrix = projection.projectionMatrix(for: CGSize(width: size, height: size))
        guard let buffer = device.makeBuffer(bytes: splats, length: MemoryLayout<SparkSplat>.stride * splats.count) else {
            throw BenchCommand.BenchError(message: "Buffer allocation failed")
        }
        buffer.label = "Bench splats"

        func frames(supersampling: Int, pointsPerThread: Int, count: Int, seedBase: UInt32) throws -> [[Float]] {
            let renderer = try PointSplatRenderer(device: device, configuration: .init(width: size, height: size, supersampling: supersampling, pointsPerThread: pointsPerThread))
            var result: [[Float]] = []
            for frame in 0..<count {
                let texture = try renderer.render(splats: buffer, splatCount: splats.count, modelMatrix: .identity, viewMatrix: cameraMatrix.inverse, projectionMatrix: projectionMatrix, frameSeed: seedBase &+ UInt32(frame))
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

    /// Reads back RGB (dropping alpha) from an rgba32Float texture.
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

    // MARK: - Output

    static func printTable(_ rows: [Row]) {
        print("")
        print("splats      renderer  median_ms  p10_ms  p90_ms")
        for row in rows {
            let splatColumn = row.splatCount.formatted(.number.grouping(.never)).padding(toLength: 11, withPad: " ", startingAt: 0)
            let rendererColumn = row.renderer.padding(toLength: 9, withPad: " ", startingAt: 0)
            print("\(splatColumn) \(rendererColumn) \(row.medianMS.formatted(.number.precision(.fractionLength(2))))       \(row.p10MS.formatted(.number.precision(.fractionLength(2))))    \(row.p90MS.formatted(.number.precision(.fractionLength(2))))")
        }
    }

    static func writeCSV(_ rows: [Row], to url: URL) throws {
        var lines = ["label,splats,renderer,median_ms,p10_ms,p90_ms"]
        for row in rows {
            lines.append("\(row.label),\(row.splatCount),\(row.renderer),\(row.medianMS),\(row.p10MS),\(row.p90MS)")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Seeded RNG so synthetic clouds are identical across runs.
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
