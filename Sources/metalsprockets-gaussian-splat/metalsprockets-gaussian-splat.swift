import AppKit
@preconcurrency import ArgumentParser
import Foundation
import GeometryLite3D
import ImageIO
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSupport
import simd
import Splats
import SwiftUI

@main
struct GaussianSplatRenderer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metalsprockets-gaussian-splat",
        abstract: "Render Gaussian splat files to PNG images",
        subcommands: [BenchCommand.self]
    )

    @Option(help: "Background color in RGBA format (e.g., 0,0,0,1 for black)")
    var background: String = "0,0,0,1"

    @Option(help: "Width of the output image")
    var width: Int = 1_024

    @Option(help: "Height of the output image")
    var height: Int = 768

    @Option(help: "Output PNG file path (default: output.png; with --statistics, omit to skip writing)")
    var output: String?

    @Option(help: "Model position in x,y,z format (e.g., 0,0,0)")
    var modelPosition: String?

    @Option(help: "Camera position in x,y,z format (e.g., 0,0,1.5)")
    var cameraPosition: String?

    @Option(help: "Camera look-at target in x,y,z format (e.g., 0,0,0)")
    var cameraLookat: String?

    @Option(help: "Camera rotation as quaternion (x,y,z,w) or 3x3 matrix (9 values comma-separated)")
    var cameraRotation: String?

    @Option(help: "Projection field of view in degrees")
    var projectionFov: Double?

    @Option(help: "Camera near clipping plane")
    var near: Float = 0.1

    @Option(help: "Camera far clipping plane")
    var far: Float = 100.0

    @Option(help: "Path to splat file (.splat, .ply, .spz, .sog) to render")
    var splat: String?

    @Option(help: "Path to JSON configuration file")
    var config: String?

    @Flag(help: "Enable Metal frame capture for debugging in Xcode")
    var capture: Bool = false

    @Option(help: "Renderer to use (spark, point, tile, stochastic)")
    var renderer: RendererKind = .spark

    @Option(help: "Point renderer supersampling factor")
    var supersampling: Int = 2

    @Option(help: "Point renderer points per thread")
    var pointsPerThread: Int = 4

    @Flag(help: "Convert sRGB to linear in fragment shader (for Spark renderer)")
    var srgbToLinear: Bool = false

    @Flag(help: "Render settings label on top of the image")
    var label: Bool = false

    @Option(help: "Override SH degree (0=off, 1-3=use specified degree)")
    var shDegree: Int?

    @Flag(help: "Reveal output file in Finder after rendering")
    var reveal: Bool = false

    @Option(help: "Export splat data to CSV file")
    var dumpCsv: String?

    @Option(help: "Sort splats on the cpu (radix sort) or gpu (cull + radix sort compute pass)")
    var sort: SortMethod = .cpu

    @Option(name: [.customLong("statistics"), .customLong("stats")], help: "Report frame timings (wall, CPU sort, GPU render with vertex/fragment breakdown) as text or json")
    var statistics: StatisticsFormat?

    @Option(help: "Frames to render and discard before measuring, to warm pipeline caches and GPU clocks")
    var warmup: Int = 0

    @Option(help: "Frames to measure (medians reported)")
    var frames: Int = 1

    func validate() throws {
        guard warmup >= 0 else {
            throw ValidationError("--warmup must not be negative")
        }
        guard frames >= 1 else {
            throw ValidationError("--frames must be at least 1")
        }
    }

    mutating func run() async throws {
        try await _run()
    }

    @MainActor
    mutating func _run() throws {
        #if !arch(x86_64)
        let renderConfig = try loadConfig()
        let device = _MTLCreateSystemDefaultDevice()
        let loadResult = try loadSplats(from: renderConfig.splat)

        note("Loaded \(loadResult.splats.count) splats, SH degree: \(loadResult.shDegree), SH coefficients: \(loadResult.shCoefficients.count)")

        if let csvPath = dumpCsv {
            try exportToCSV(loadResult: loadResult, path: csvPath)
            print("Exported \(loadResult.splats.count) splats to \(csvPath)")
            return
        }

        let modelMatrix = try parseModelMatrix(from: renderConfig)
        let cameraMatrix = try parseCameraMatrix(from: renderConfig)
        let useSrgbToLinear = renderConfig.srgbToLinear ?? false

        let (sparkGPUSplatCloud, shCoefficientsBuffer, effectiveSHDegree) = try createGPUSplatClouds(
            loadResult: loadResult,
            device: device,
            modelMatrix: modelMatrix
        )

        note("Effective SH degree: \(effectiveSHDegree), SH buffer: \(shCoefficientsBuffer != nil ? "yes" : "no")")

        let size = CGSize(width: renderConfig.width, height: renderConfig.height)
        let projection = try createProjection(from: renderConfig)
        let bgColor = renderConfig.getBackground()

        guard let rendererKind = RendererKind(rawValue: renderConfig.renderer ?? "spark") else {
            throw ValidationError("Unknown renderer: \(renderConfig.renderer ?? ""). Supported: \(RendererKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if sort == .gpu, rendererKind != .spark {
            throw ValidationError("--sort gpu only applies to the spark renderer")
        }

        // A statistics run with no explicit destination is measurement-only.
        let needsImage = statistics == nil || output != nil || config != nil

        let (image, splatCount, samples) = try performRender(
            size: size,
            rendererKind: rendererKind,
            projection: projection,
            bgColor: bgColor,
            useSrgbToLinear: useSrgbToLinear,
            near: renderConfig.near,
            far: renderConfig.far,
            modelMatrix: modelMatrix,
            cameraMatrix: cameraMatrix,
            sparkGPUSplatCloud: sparkGPUSplatCloud,
            needsImage: needsImage
        )

        if let statistics {
            let report = makeReport(samples: samples, splats: splatCount, shDegree: Int(effectiveSHDegree), width: renderConfig.width, height: renderConfig.height, warmup: warmup, renderer: rendererKind, sortMethod: sort)
            try emitReport(report, format: statistics)
        }

        if var cgImage = image {
            if label {
                cgImage = addLabel(to: cgImage, renderConfig: renderConfig, splatCount: splatCount, useSrgbToLinear: useSrgbToLinear, effectiveSHDegree: effectiveSHDegree)
            }

            try saveOutput(cgImage: cgImage, to: renderConfig.output, reveal: reveal)
        }
        #else
        throw ValidationError("This tool requires Apple Silicon (ARM64) on macOS")
        #endif
    }

    /// Chatter that isn't the report. In JSON mode it goes to stderr so stdout
    /// stays a single parseable document.
    private func note(_ message: String) {
        if statistics == .json {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        } else {
            print(message)
        }
    }

    // MARK: - Config Loading

    mutating func loadConfig() throws -> RenderConfig {
        var renderConfig: RenderConfig
        if let configPath = config {
            renderConfig = try RenderConfig.load(from: configPath)
            try applyCliOverrides(to: &renderConfig)
        } else {
            guard let splatPath = splat else {
                throw ValidationError("Must specify a splat file with --splat or use --config")
            }
            renderConfig = try buildConfigFromCli(splatPath: splatPath)
        }

        let splatPath = renderConfig.splat
        guard FileManager.default.fileExists(atPath: splatPath) else {
            throw ValidationError("Splat file not found: \(splatPath)")
        }

        return renderConfig
    }

    mutating func applyCliOverrides(to renderConfig: inout RenderConfig) throws {
        if background != "0,0,0,1" {
            let bgComponents = try parseRGBA(background)
            renderConfig.background = [bgComponents.x, bgComponents.y, bgComponents.z, bgComponents.w]
        }
        if width != 1_024 { renderConfig.width = width }
        if height != 768 { renderConfig.height = height }
        if let output { renderConfig.output = output }
        if let pos = modelPosition {
            let v = try parseXYZ(pos)
            renderConfig.modelPosition = [v.x, v.y, v.z]
        }
        if let pos = cameraPosition {
            let v = try parseXYZ(pos)
            renderConfig.cameraPosition = [v.x, v.y, v.z]
        }
        if let lookat = cameraLookat {
            let v = try parseXYZ(lookat)
            renderConfig.cameraLookat = [v.x, v.y, v.z]
        }
        if let rot = cameraRotation {
            renderConfig.cameraRotation = rot.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        }
        if let fov = projectionFov { renderConfig.projectionFov = fov }
        if near != 0.1 { renderConfig.near = near }
        if far != 100.0 { renderConfig.far = far }
        if let s = splat { renderConfig.splat = s }
        if renderer != .spark { renderConfig.renderer = renderer.rawValue }
        if srgbToLinear { renderConfig.srgbToLinear = true }
    }

    func buildConfigFromCli(splatPath: String) throws -> RenderConfig {
        let bgComponents = try parseRGBA(background)
        return RenderConfig(
            background: [bgComponents.x, bgComponents.y, bgComponents.z, bgComponents.w],
            width: width,
            height: height,
            output: output ?? "output.png",
            modelPosition: try modelPosition.map { let v = try parseXYZ($0); return [v.x, v.y, v.z] },
            cameraPosition: try cameraPosition.map { let v = try parseXYZ($0); return [v.x, v.y, v.z] },
            cameraLookat: try cameraLookat.map { let v = try parseXYZ($0); return [v.x, v.y, v.z] },
            cameraRotation: cameraRotation?.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) },
            projectionFov: projectionFov,
            near: near,
            far: far,
            splat: splatPath,
            renderer: renderer.rawValue,
            srgbToLinear: srgbToLinear
        )
    }

    // MARK: - Splat Loading

    /// Result of loading splats, including optional SH data
    struct SplatLoadResult {
        let splats: [GenericSplat]
        let shCoefficients: [Float]
        let shDegree: UInt8
    }

    #if !arch(x86_64)
    func loadSplats(from splatPath: String) throws -> SplatLoadResult {
        let splatURL = URL(fileURLWithPath: splatPath)
        let fileExtension = splatURL.pathExtension.lowercased()

        var splats: [GenericSplat] = []
        var shCoefficients: [Float] = []
        var detectedSHDegree: UInt8 = 0

        switch fileExtension {
        case "spz":
            let reader = try Splats.SPZReader(url: splatURL)
            detectedSHDegree = reader.shDegree
            let floatsPerSplat = Self.shFloatsPerSplat(degree: detectedSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(reader.splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(extendedSplat.genericSplat)
                if let sh = extendedSplat.sphericalHarmonics {
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }

        case "ply":
            let reader = try PLYSplatReader(url: splatURL)
            detectedSHDegree = reader.shDegree
            let floatsPerSplat = Self.shFloatsPerSplat(degree: detectedSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(reader.splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(extendedSplat.genericSplat)
                if let sh = extendedSplat.sphericalHarmonics {
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }

        case "sog":
            let reader = try SOGReaderCPU(url: splatURL)
            detectedSHDegree = UInt8(reader.shDegree)
            let floatsPerSplat = Self.shFloatsPerSplat(degree: detectedSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(reader.splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(extendedSplat.genericSplat)
                if let sh = extendedSplat.sphericalHarmonics {
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }

        default:
            throw ValidationError("Unsupported file format: .\(fileExtension)")
        }

        return SplatLoadResult(splats: splats, shCoefficients: shCoefficients, shDegree: detectedSHDegree)
    }

    /// Returns the number of floats per splat for a given SH degree
    private static func shFloatsPerSplat(degree: UInt8) -> Int {
        switch degree {
        case 0:
            return 0
        case 1:
            return 3 * 3   // 3 basis functions * 3 channels (RGB)
        case 2:
            return 8 * 3   // 8 basis functions * 3 channels
        case 3:
            return 15 * 3  // 15 basis functions * 3 channels
        default:
            return 0
        }
    }

    // MARK: - CSV Export

    func exportToCSV(loadResult: SplatLoadResult, path: String) throws {
        var csv = "index,pos_x,pos_y,pos_z,scale_x,scale_y,scale_z,rot_x,rot_y,rot_z,rot_w,r,g,b,a"

        let floatsPerSplat = Self.shFloatsPerSplat(degree: loadResult.shDegree)
        let numCoeffs = floatsPerSplat / 3
        for i in 0..<numCoeffs {
            csv += ",sh\(i)_r,sh\(i)_g,sh\(i)_b"
        }
        csv += "\n"

        for (index, splat) in loadResult.splats.enumerated() {
            var row = "\(index)"
            row += ",\(splat.position.x),\(splat.position.y),\(splat.position.z)"
            row += ",\(splat.scale.x),\(splat.scale.y),\(splat.scale.z)"
            row += ",\(splat.rotation.x),\(splat.rotation.y),\(splat.rotation.z),\(splat.rotation.w)"
            row += ",\(splat.color.x),\(splat.color.y),\(splat.color.z),\(splat.color.w)"

            if floatsPerSplat > 0, !loadResult.shCoefficients.isEmpty {
                let baseOffset = index * floatsPerSplat
                for i in 0..<numCoeffs {
                    let r = loadResult.shCoefficients[baseOffset + i * 3]
                    let g = loadResult.shCoefficients[baseOffset + i * 3 + 1]
                    let b = loadResult.shCoefficients[baseOffset + i * 3 + 2]
                    row += ",\(r),\(g),\(b)"
                }
            }

            csv += row + "\n"
        }

        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Splat Cloud Creation

    func createGPUSplatClouds(
        loadResult: SplatLoadResult,
        device: MTLDevice,
        modelMatrix: simd_float4x4
    ) throws -> (GPUSplatCloud<SparkSplat>, TypedMTLBuffer<Float>?, UInt8) {
        let effectiveSHDegree: UInt8
        if let override = shDegree {
            effectiveSHDegree = UInt8(override)
        } else {
            effectiveSHDegree = loadResult.shDegree
        }

        var shCoefficientsBuffer: TypedMTLBuffer<Float>?
        if !loadResult.shCoefficients.isEmpty, effectiveSHDegree > 0 {
            shCoefficientsBuffer = try device.makeTypedBuffer(values: loadResult.shCoefficients, options: []).labeled("SHCoefficients")
        }

        let gpuSplats = loadResult.splats.map { SparkSplat($0) }
        let splatBuffer = try device.makeTypedBuffer(values: gpuSplats, options: []).labeled("Splats")
        let sparkGPUSplatCloud: GPUSplatCloud<SparkSplat>
        if let shBuffer = shCoefficientsBuffer {
            sparkGPUSplatCloud = GPUSplatCloud<SparkSplat>(
                splats: splatBuffer,
                modelTransform: modelMatrix,
                shCoefficients: shBuffer,
                shDegree: effectiveSHDegree
            )
        } else {
            sparkGPUSplatCloud = GPUSplatCloud<SparkSplat>(
                splats: splatBuffer,
                modelTransform: modelMatrix
            )
        }
        return (sparkGPUSplatCloud, shCoefficientsBuffer, effectiveSHDegree)
    }

    // MARK: - Rendering

    @MainActor
    func performRender(
        size: CGSize,
        rendererKind: RendererKind,
        projection: any ProjectionProtocol,
        bgColor: SIMD4<Float>,
        useSrgbToLinear: Bool,
        near: Float,
        far: Float,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        sparkGPUSplatCloud: GPUSplatCloud<SparkSplat>,
        needsImage: Bool
    ) throws -> (CGImage?, Int, [FrameSample]) {
        let cloud = sparkGPUSplatCloud
        let splatCount = cloud.count
        let aspectRatio = Float(size.width) / Float(size.height)
        let projectionMatrix = projection.projectionMatrix(aspectRatio: aspectRatio)
        let drawableSize = SIMD2<Float>(Float(size.width), Float(size.height))
        let renderSampleBox = GPUSampleBox()
        let sortSampleBox = GPUSampleBox()
        let collectSamples = statistics != nil
        let sortParameters = SortParameters(camera: cameraMatrix, model: modelMatrix)
        var frameIndex: UInt32 = 0

        // The point renderer has an imperative API (it owns its own compute
        // pipelines and float output texture), so it bypasses OffscreenRenderer.
        if rendererKind == .point {
            let pointRenderer = try PointSplatRenderer(
                device: _MTLCreateSystemDefaultDevice(),
                configuration: .init(
                    width: Int(size.width),
                    height: Int(size.height),
                    nearPlane: near,
                    farPlane: far,
                    backgroundColor: SIMD3<Float>(bgColor.x, bgColor.y, bgColor.z),
                    supersampling: supersampling,
                    pointsPerThread: pointsPerThread
                )
            )
            if collectSamples {
                pointRenderer.onGPUCounterSample = { renderSampleBox.set($0) }
            }
            var lastTexture: MTLTexture?
            var samples: [FrameSample] = []
            func pointFrame() throws -> FrameSample {
                let start = ContinuousClock.now
                lastTexture = try pointRenderer.render(
                    splats: cloud.splats.unsafeMTLBuffer,
                    splatCount: splatCount,
                    modelMatrix: modelMatrix,
                    viewMatrix: cameraMatrix.inverse,
                    projectionMatrix: projectionMatrix,
                    frameSeed: frameIndex
                )
                frameIndex += 1
                return FrameSample(wallTime: elapsedSeconds(since: start), render: renderSampleBox.take())
            }
            for _ in 0..<warmup {
                _ = try pointFrame()
            }
            for _ in 0..<frames {
                samples.append(try pointFrame())
            }
            guard let lastTexture else {
                throw ValidationError("No frames rendered")
            }
            return (needsImage ? try makeImage(fromFloatTexture: lastTexture) : nil, splatCount, samples)
        }

        let renderer = try OffscreenRenderer(size: size)
        renderer.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bgColor.x),
            green: Double(bgColor.y),
            blue: Double(bgColor.z),
            alpha: Double(bgColor.w)
        )
        let gpuSortResources = (rendererKind == .spark && sort == .gpu) ? try GPUSortResources(device: renderer.device, capacity: cloud.count, slotCount: 1) : nil

        func makeRenderPass(sortedIndices: SplatIndices) throws -> some Element {
            try RenderPass {
                try SparkSplatRenderPipeline(
                    splatCloud: cloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: drawableSize,
                    configuration: .init(convertSRGBToLinear: useSrgbToLinear),
                    sortedIndices: sortedIndices
                )
            }
        }

        // Spark frame: sort, then render the indices it produced. Warm-up
        // frames run this unchanged so they exercise exactly the measured work.
        func sparkFrame() throws -> (OffscreenRenderer.Rendering, FrameSample) {
            let start = ContinuousClock.now
            let rendering: OffscreenRenderer.Rendering
            var sortCPUTime: TimeInterval?
            var visibleSplats: Int?
            if let gpuSortResources {
                // Sort and render in one submission, mirroring
                // GPUSortedSplatRenderPipeline but with counters on each pass.
                let slot = gpuSortResources.advance()
                let sortedIndices = gpuSortResources.makeIndices(slot: slot, count: cloud.count, parameters: sortParameters)
                let sortPass = try GPUSplatSortComputePass(
                    splatCloud: cloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    resources: gpuSortResources,
                    slotIndex: slot
                )
                let renderPass = try makeRenderPass(sortedIndices: sortedIndices)
                if collectSamples {
                    rendering = try renderer.render(Group {
                        sortPass.gpuCounters(label: "splat sort") { sortSampleBox.set($0) }
                        renderPass.gpuCounters(label: "splat render") { renderSampleBox.set($0) }
                    })
                } else {
                    rendering = try renderer.render(Group {
                        sortPass
                        renderPass
                    })
                }
                visibleSplats = gpuSortResources.lastSurvivorCount
            } else {
                let sortedIndices = try SplatSorter.sort(device: renderer.device, splatCloud: cloud, parameters: sortParameters)
                sortCPUTime = elapsedSeconds(since: start)
                let renderPass = try makeRenderPass(sortedIndices: sortedIndices)
                if collectSamples {
                    rendering = try renderer.render(renderPass.gpuCounters(label: "splat render") { renderSampleBox.set($0) })
                } else {
                    rendering = try renderer.render(renderPass)
                }
            }
            return (rendering, FrameSample(
                wallTime: elapsedSeconds(since: start),
                sortCPUTime: sortCPUTime,
                sortGPU: sortSampleBox.take(),
                render: renderSampleBox.take(),
                visibleSplats: visibleSplats
            ))
        }

        // Tile frame: binning/sorting compute passes plus the tile render pass,
        // all inside one element. Counters report the render pass only.
        func tileFrame() throws -> (OffscreenRenderer.Rendering, FrameSample) {
            let start = ContinuousClock.now
            let pass = try TileBasedSplatPass(
                splatCloud: cloud,
                projection: projection,
                drawableSize: drawableSize,
                cameraMatrix: cameraMatrix,
                modelMatrix: modelMatrix
            )
            let rendering: OffscreenRenderer.Rendering
            if collectSamples {
                rendering = try renderer.render(pass.gpuCounters(label: "splat render") { renderSampleBox.set($0) })
            } else {
                rendering = try renderer.render(pass)
            }
            return (rendering, FrameSample(wallTime: elapsedSeconds(since: start), render: renderSampleBox.take()))
        }

        // Stochastic frame: single unaccumulated frame, so the output is noisy
        // by design; the seed advances per frame like an interactive session.
        func stochasticFrame() throws -> (OffscreenRenderer.Rendering, FrameSample) {
            let start = ContinuousClock.now
            let pass = try RenderPass {
                try StochasticSplatRenderPipeline(
                    splatCloud: cloud,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: drawableSize,
                    frameTime: frameIndex,
                    convertSRGBToLinear: useSrgbToLinear
                )
                .depthCompare(function: .less, enabled: true)
            }
            let rendering: OffscreenRenderer.Rendering
            if collectSamples {
                rendering = try renderer.render(pass.gpuCounters(label: "splat render") { renderSampleBox.set($0) })
            } else {
                rendering = try renderer.render(pass)
            }
            return (rendering, FrameSample(wallTime: elapsedSeconds(since: start), render: renderSampleBox.take()))
        }

        func renderFrame() throws -> (OffscreenRenderer.Rendering, FrameSample) {
            defer {
                frameIndex += 1
            }
            switch rendererKind {
            case .spark:
                return try sparkFrame()

            case .tile:
                return try tileFrame()

            case .stochastic:
                return try stochasticFrame()

            case .point:
                throw ValidationError("point renderer handled separately")
            }
        }

        var lastRendering: OffscreenRenderer.Rendering?
        var samples: [FrameSample] = []
        try MTLCaptureManager.shared().with(enabled: capture) {
            for _ in 0..<warmup {
                (lastRendering, _) = try renderFrame()
            }
            for _ in 0..<frames {
                let (rendering, sample) = try renderFrame()
                lastRendering = rendering
                samples.append(sample)
            }
        }
        guard let lastRendering else {
            throw ValidationError("No frames rendered")
        }

        return (needsImage ? try lastRendering.cgImage : nil, splatCount, samples)
    }

    /// Converts the point renderer's rgba32Float output to an 8-bit image.
    ///
    /// Values are sRGB-encoded to match the element renderers, which write
    /// into an sRGB framebuffer.
    @MainActor
    func makeImage(fromFloatTexture texture: MTLTexture) throws -> CGImage {
        if texture.storageMode == .managed {
            let runner = try Runner(device: texture.device)
            try runner.run(
                BlitPass {
                    Blit { encoder in
                        encoder.synchronize(resource: texture)
                    }
                }
            )
        }
        let pixelCount = texture.width * texture.height
        var rgba = [Float](repeating: 0, count: pixelCount * 4)
        rgba.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return
            }
            texture.getBytes(baseAddress, bytesPerRow: texture.width * 16, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        var bytes = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixel in 0..<pixelCount {
            for channel in 0..<3 {
                let value = max(0, min(1, rgba[pixel * 4 + channel]))
                let encoded = value <= 0.003_130_8 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
                bytes[pixel * 4 + channel] = UInt8(encoded * 255 + 0.5)
            }
            bytes[pixel * 4 + 3] = 255
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(data: &bytes, width: texture.width, height: texture.height, bitsPerComponent: 8, bytesPerRow: texture.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue), let image = context.makeImage() else {
            throw ValidationError("Failed to convert point renderer output to an image")
        }
        return image
    }

    // MARK: - Label Overlay

    @MainActor
    func addLabel(to cgImage: CGImage, renderConfig: RenderConfig, splatCount: Int, useSrgbToLinear: Bool, effectiveSHDegree: UInt8) -> CGImage {
        let fovStr = renderConfig.projectionFov.map { $0.formatted(.number.precision(.fractionLength(1))) + "°" } ?? "60°"
        let camPos = renderConfig.getCameraPosition() ?? SIMD3<Float>(0, 0, 1.5)
        let modelPos = renderConfig.getModelPosition() ?? SIMD3<Float>(0, 0, 0)

        let shInfo = " | SH: \(effectiveSHDegree > 0 ? "deg \(effectiveSHDegree)" : "off")"
        let labelText = """
        Renderer: Spark | sRGB→Linear: \(useSrgbToLinear)\(shInfo)
        Size: \(renderConfig.width)x\(renderConfig.height) | FOV: \(fovStr)
        Splats: \(splatCount) | Near/Far: \(renderConfig.near)/\(renderConfig.far)
        Camera: (\(camPos.x.formatted(.number.precision(.fractionLength(2)))), \(camPos.y.formatted(.number.precision(.fractionLength(2)))), \(camPos.z.formatted(.number.precision(.fractionLength(2)))))
        Model: (\(modelPos.x.formatted(.number.precision(.fractionLength(2)))), \(modelPos.y.formatted(.number.precision(.fractionLength(2)))), \(modelPos.z.formatted(.number.precision(.fractionLength(2)))))
        """

        let labelView = ZStack(alignment: .bottomLeading) {
            Image(decorative: cgImage, scale: 1.0)
            Text(labelText)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .padding(8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(4)
                .padding(10)
        }

        let renderer = ImageRenderer(content: labelView)
        renderer.scale = 1.0
        return renderer.cgImage ?? cgImage
    }

    // MARK: - Output Saving

    func saveOutput(cgImage: CGImage, to outputPath: String, reveal: Bool) throws {
        var finalPath = outputPath
        if !finalPath.hasPrefix("/") {
            finalPath = FileManager.default.currentDirectoryPath + "/" + finalPath
        }

        let outputURL = URL(fileURLWithPath: finalPath)
        if let parentDir = outputURL.deletingLastPathComponent().path as String? {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw ValidationError("Failed to create image destination")
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw ValidationError("Failed to write image to \(outputPath)")
        }

        if reveal {
            NSWorkspace.shared.selectFile(finalPath, inFileViewerRootedAtPath: "")
        }
    }
    #endif

    // MARK: - Helper Functions

    func parseRGBA(_ string: String) throws -> SIMD4<Float> {
        let components = string.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 4 else {
            throw ValidationError("Background color must be in RGBA format (4 comma-separated values)")
        }
        return SIMD4<Float>(components[0], components[1], components[2], components[3])
    }

    func parseXYZ(_ string: String) throws -> SIMD3<Float> {
        let components = string.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count == 3 else {
            throw ValidationError("Position must be in x,y,z format (3 comma-separated values)")
        }
        return SIMD3<Float>(components[0], components[1], components[2])
    }

    func parseModelMatrix(from config: RenderConfig) throws -> simd_float4x4 {
        if let position = config.getModelPosition() {
            return simd_float4x4(translation: position)
        }
        return .identity
    }

    func parseCameraMatrix(from config: RenderConfig) throws -> simd_float4x4 {
        // Priority: rotation > lookat > position
        if let rotation = config.getCameraRotation() {
            return try parseCameraRotationMatrix(rotation, config: config)
        }

        if let target = config.getCameraLookat() {
            let position = config.getCameraPosition() ?? SIMD3<Float>(0, 0, 1.5)
            return LookAt(position: position, target: target, up: SIMD3<Float>(0, 1, 0)).cameraMatrix
        }

        if let position = config.getCameraPosition() {
            return simd_float4x4(translation: position)
        }

        return LookAt(position: SIMD3<Float>(0, 0, 1.5), target: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0)).cameraMatrix
    }

    func parseCameraRotationMatrix(_ components: [Float], config: RenderConfig) throws -> simd_float4x4 {
        if components.count == 4 {
            // Quaternion components in (x, y, z, w) order.
            let quat = simd_quatf(ix: components[0], iy: components[1], iz: components[2], r: components[3])
            let rotationMatrix = simd_float4x4(quat)

            if let position = config.getCameraPosition() {
                var matrix = rotationMatrix
                matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
                return matrix
            }
            return rotationMatrix
        }
        if components.count == 9 {
            // Row-major 3x3 rotation matrix.
            let matrix = simd_float4x4(
                SIMD4<Float>(components[0], components[1], components[2], 0),
                SIMD4<Float>(components[3], components[4], components[5], 0),
                SIMD4<Float>(components[6], components[7], components[8], 0),
                SIMD4<Float>(0, 0, 0, 1)
            )

            if let position = config.getCameraPosition() {
                var finalMatrix = matrix
                finalMatrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
                return finalMatrix
            }
            return matrix
        }
        throw ValidationError("Camera rotation must be either 4 values (quaternion x,y,z,w) or 9 values (3x3 matrix)")
    }

    func createProjection(from config: RenderConfig) throws -> any ProjectionProtocol {
        let angleOfView = config.projectionFov.map { AngleF.degrees(Float($0)) } ?? AngleF.degrees(60)
        return PerspectiveProjection(
            verticalAngleOfView: angleOfView,
            depthMode: .standard(zClip: config.near...config.far)
        )
    }
}

// MARK: - Matrix Extensions

extension simd_float4x4 {
    init(translation: SIMD3<Float>) {
        self.init(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        )
    }
}
