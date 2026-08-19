#if !arch(x86_64)

import CoreGraphics
import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSupport
import simd
import Splats

/// Renders offscreen frames of a splat cloud with any of the splat renderers
/// behind one interface.
///
/// This type hides the per-renderer differences in pass shape, sorting, and
/// output format. Spark needs sorted indices from a CPU or GPU sort. Tile and
/// stochastic are self-contained passes. Point is compute-only and writes a
/// float output texture.
///
/// ```swift
/// let renderer = try OffscreenSplatRenderer(
///     renderer: .spark(sort: .gpu),
///     splatCloud: cloud,
///     projection: PerspectiveProjection(),
///     cameraMatrix: cameraMatrix,
///     modelMatrix: .identity,
///     configuration: .init(width: 1_024, height: 768)
/// )
/// let report = try renderer.renderFrame()
/// let image = try renderer.makeImage()
/// ```
///
/// Each ``renderFrame()`` call blocks until the GPU completes. It then advances
/// the stochastic frame seed, so repeated calls behave like successive
/// interactive frames. Set ``Configuration/collectGPUCounters`` to receive GPU
/// timestamp samples in the returned ``FrameReport``.
@MainActor
public final class OffscreenSplatRenderer {
    /// Which splat renderer draws the frame.
    public enum Renderer: Equatable, Sendable {
        /// Sorted alpha-blended splats; the production renderer.
        case spark(sort: SortMethod)
        /// Tile-based binning renderer (experimental).
        case tile
        /// Stochastic transparency, one unaccumulated (noisy) frame per call.
        case stochastic
        /// Sort-free stochastic point splatting, one noisy frame per call.
        case point
    }

    /// How the spark renderer sorts splats each frame.
    public enum SortMethod: String, CaseIterable, Sendable {
        /// Blocking CPU radix sort.
        case cpu
        /// Cull and radix sort compute pass in the same submission as the render.
        case gpu
    }

    public struct Configuration {
        public var width: Int
        public var height: Int
        public var backgroundColor: SIMD4<Float>
        public var convertSRGBToLinear: Bool
        /// View-space depth range. The point renderer uses it for depth
        /// quantization and the near cull.
        public var nearPlane: Float
        public var farPlane: Float
        /// Point renderer supersampling factor S.
        public var pointSupersampling: Int
        /// Point renderer points per thread K.
        public var pointPointsPerThread: Int
        /// Sample GPU timestamps each frame and report them in ``FrameReport``.
        public var collectGPUCounters: Bool

        public init(
            width: Int,
            height: Int,
            backgroundColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
            convertSRGBToLinear: Bool = false,
            nearPlane: Float = 0.1,
            farPlane: Float = 100.0,
            pointSupersampling: Int = 2,
            pointPointsPerThread: Int = 4,
            collectGPUCounters: Bool = false
        ) {
            self.width = width
            self.height = height
            self.backgroundColor = backgroundColor
            self.convertSRGBToLinear = convertSRGBToLinear
            self.nearPlane = nearPlane
            self.farPlane = farPlane
            self.pointSupersampling = pointSupersampling
            self.pointPointsPerThread = pointPointsPerThread
            self.collectGPUCounters = collectGPUCounters
        }
    }

    /// Timings and stats for one rendered frame. A field is `nil` when the
    /// renderer or configuration does not produce it.
    public struct FrameReport: Sendable {
        /// Blocking CPU radix sort time (spark with ``SortMethod/cpu``).
        public var sortCPUTime: TimeInterval?
        /// GPU sort compute pass sample (spark with ``SortMethod/gpu``).
        public var sortGPU: GPUCounterSample?
        /// Main pass sample: the render pass time with vertex and fragment
        /// intervals, or the whole-encoder compute time for the point renderer.
        public var render: GPUCounterSample?
        /// Frustum-cull survivors (spark with ``SortMethod/gpu``; the GPU sort
        /// is the only path that culls).
        public var visibleSplats: Int?
        /// Whole-submission GPU time from the command-buffer clock
        /// (`gpuEndTime - gpuStartTime`), correlation-free. `nil` if unavailable.
        /// For the GPU sort path this spans sort and render (one submission).
        public var commandBufferGPUTime: TimeInterval?
    }

    public let renderer: Renderer
    public let configuration: Configuration

    private let splatCloud: GPUSplatCloud<SparkSplat>
    private let projection: any ProjectionProtocol
    private let projectionMatrix: simd_float4x4
    private let cameraMatrix: simd_float4x4
    private let modelMatrix: simd_float4x4
    private let drawableSize: SIMD2<Float>
    private let sortParameters: SortParameters
    private var frameIndex: UInt32 = 0

    private let renderSampleBox = SampleBox()
    private let sortSampleBox = SampleBox()

    // Element renderers draw into this; nil for point.
    private let offscreenRenderer: OffscreenRenderer?
    // Spark with the GPU sort.
    private let gpuSortResources: GPUSortResources?
    // The point renderer is compute-only. It resolves into this float texture
    // through its own runner, not the offscreen renderer's render target.
    private let pointRunner: Runner?
    private let pointTexture: MTLTexture?

    /// - Parameters:
    ///   - renderer: Which splat renderer draws the frames.
    ///   - splatCloud: The splat cloud to render.
    ///   - projection: The camera projection. Its matrix comes from the
    ///     configured aspect ratio.
    ///   - cameraMatrix: The camera (view-to-world) matrix.
    ///   - modelMatrix: The scene-level model transform.
    ///   - configuration: Size, colors, and renderer options.
    ///   - device: The Metal device. Defaults to the system default device.
    public init(
        renderer: Renderer,
        splatCloud: GPUSplatCloud<SparkSplat>,
        projection: any ProjectionProtocol,
        cameraMatrix: simd_float4x4,
        modelMatrix: simd_float4x4 = .identity,
        configuration: Configuration,
        device: MTLDevice? = nil
    ) throws {
        self.renderer = renderer
        self.configuration = configuration
        self.splatCloud = splatCloud
        self.projection = projection
        let aspectRatio = Float(configuration.width) / Float(configuration.height)
        self.projectionMatrix = projection.projectionMatrix(aspectRatio: aspectRatio)
        self.cameraMatrix = cameraMatrix
        self.modelMatrix = modelMatrix
        self.drawableSize = SIMD2<Float>(Float(configuration.width), Float(configuration.height))
        self.sortParameters = SortParameters(camera: cameraMatrix, model: modelMatrix)
        let device = device ?? _MTLCreateSystemDefaultDevice()

        switch renderer {
        case .point:
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: configuration.width, height: configuration.height, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw PointSplatError.textureAllocationFailed
            }
            texture.label = "PointSplat resolve"
            self.pointRunner = try Runner(device: device)
            self.pointTexture = texture
            self.offscreenRenderer = nil
            self.gpuSortResources = nil

        case .spark(let sort):
            let offscreenRenderer = try Self.makeOffscreenRenderer(device: device, configuration: configuration)
            self.offscreenRenderer = offscreenRenderer
            self.gpuSortResources = sort == .gpu ? try GPUSortResources(device: offscreenRenderer.device, capacity: splatCloud.count, slotCount: 1) : nil
            self.pointRunner = nil
            self.pointTexture = nil

        case .tile, .stochastic:
            self.offscreenRenderer = try Self.makeOffscreenRenderer(device: device, configuration: configuration)
            self.gpuSortResources = nil
            self.pointRunner = nil
            self.pointTexture = nil
        }
    }

    private static func makeOffscreenRenderer(device: MTLDevice, configuration: Configuration) throws -> OffscreenRenderer {
        let renderer = try OffscreenRenderer(size: CGSize(width: configuration.width, height: configuration.height), device: device)
        renderer.renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(configuration.backgroundColor.x),
            green: Double(configuration.backgroundColor.y),
            blue: Double(configuration.backgroundColor.z),
            alpha: Double(configuration.backgroundColor.w)
        )
        return renderer
    }

    /// Renders one frame, blocking until the GPU completes.
    @discardableResult
    public func renderFrame() throws -> FrameReport {
        defer {
            frameIndex += 1
        }
        switch renderer {
        case .spark(let sort):
            return try renderSparkFrame(sort: sort)

        case .tile:
            return try renderTileFrame()

        case .stochastic:
            return try renderStochasticFrame()

        case .point:
            return try renderPointFrame()
        }
    }

    /// The last rendered frame as an image.
    ///
    /// Call this after at least one ``renderFrame()``.
    public func makeImage() throws -> CGImage {
        if let pointTexture {
            return try Self.makeImage(fromRGBA32Float: pointTexture)
        }
        guard let offscreenRenderer else {
            throw MetalSprocketsError.generic("No frame rendered yet")
        }
        return try offscreenRenderer.colorTexture.toCGImage()
    }

    // MARK: - Per-renderer frames

    private func renderSparkFrame(sort _: SortMethod) throws -> FrameReport {
        guard let offscreenRenderer else {
            throw MetalSprocketsError.generic("Renderer not configured")
        }
        var report = FrameReport()
        if let gpuSortResources {
            // Sort and render in one submission, like GPUSortedSplatRenderPipeline
            // but with counters on each pass.
            let slot = gpuSortResources.advance()
            let sortedIndices = gpuSortResources.makeIndices(slot: slot, count: splatCloud.count, parameters: sortParameters)
            let sortPass = try GPUSplatSortComputePass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                resources: gpuSortResources,
                slotIndex: slot
            )
            let renderPass = try makeSparkRenderPass(sortedIndices: sortedIndices)
            if configuration.collectGPUCounters {
                let sortBox = sortSampleBox
                let renderBox = renderSampleBox
                report.commandBufferGPUTime = try offscreenRenderer.render(Group {
                    sortPass.gpuCounters(label: "splat sort") { sortBox.set($0) }
                    renderPass.gpuCounters(label: "splat render") { renderBox.set($0) }
                }).gpuTime
            } else {
                report.commandBufferGPUTime = try offscreenRenderer.render(Group {
                    sortPass
                    renderPass
                }).gpuTime
            }
            report.visibleSplats = gpuSortResources.lastSurvivorCount
        } else {
            let start = ContinuousClock.now
            let sortedIndices = try SplatSorter.sort(device: offscreenRenderer.device, splatCloud: splatCloud, parameters: sortParameters)
            let elapsed = ContinuousClock.now - start
            report.sortCPUTime = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
            report.commandBufferGPUTime = try render(pass: makeSparkRenderPass(sortedIndices: sortedIndices), in: offscreenRenderer)
        }
        report.sortGPU = sortSampleBox.take()
        report.render = renderSampleBox.take()
        return report
    }

    private func makeSparkRenderPass(sortedIndices: SplatIndices) throws -> some Element {
        try RenderPass {
            try SparkSplatRenderPipeline(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                configuration: .init(convertSRGBToLinear: configuration.convertSRGBToLinear),
                sortedIndices: sortedIndices
            )
        }
    }

    /// Counters report the final tile render pass. The binning and sorting
    /// compute passes share its sample buffer and are not reported.
    private func renderTileFrame() throws -> FrameReport {
        guard let offscreenRenderer else {
            throw MetalSprocketsError.generic("Renderer not configured")
        }
        let pass = try TileBasedSplatPass(
            splatCloud: splatCloud,
            projection: projection,
            drawableSize: drawableSize,
            cameraMatrix: cameraMatrix,
            modelMatrix: modelMatrix
        )
        try render(pass: pass, in: offscreenRenderer)
        return FrameReport(render: renderSampleBox.take())
    }

    private func renderStochasticFrame() throws -> FrameReport {
        guard let offscreenRenderer else {
            throw MetalSprocketsError.generic("Renderer not configured")
        }
        let pass = try RenderPass {
            try StochasticSplatRenderPipeline(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                frameTime: frameIndex,
                convertSRGBToLinear: configuration.convertSRGBToLinear
            )
            .depthCompare(function: .less, enabled: true)
        }
        try render(pass: pass, in: offscreenRenderer)
        return FrameReport(render: renderSampleBox.take())
    }

    private func renderPointFrame() throws -> FrameReport {
        guard let pointRunner, let pointTexture else {
            throw MetalSprocketsError.generic("Renderer not configured")
        }
        // frameIndex is monotonic, so it doubles as the frame-plan key.
        let pass = PointSplatComputePass(
            splatCloud: splatCloud,
            modelMatrix: modelMatrix,
            viewMatrix: cameraMatrix.inverse,
            projectionMatrix: projectionMatrix,
            frameSeed: frameIndex,
            outTexture: pointTexture,
            nearPlane: configuration.nearPlane,
            farPlane: configuration.farPlane,
            backgroundColor: SIMD3<Float>(configuration.backgroundColor.x, configuration.backgroundColor.y, configuration.backgroundColor.z),
            supersampling: configuration.pointSupersampling,
            pointsPerThread: configuration.pointPointsPerThread
        )
        if configuration.collectGPUCounters {
            let box = renderSampleBox
            try pointRunner.run(pass.gpuCounters(label: "splat render") { box.set($0) })
        } else {
            try pointRunner.run(pass)
        }
        return FrameReport(render: renderSampleBox.take())
    }

    /// Renders the pass and returns the command-buffer GPU time, if available.
    @discardableResult
    private func render(pass: some Element, in offscreenRenderer: OffscreenRenderer) throws -> TimeInterval? {
        if configuration.collectGPUCounters {
            let box = renderSampleBox
            return try offscreenRenderer.render(pass.gpuCounters(label: "splat render") { box.set($0) }).gpuTime
        } else {
            return try offscreenRenderer.render(pass).gpuTime
        }
    }

    // MARK: - Point image conversion

    /// Converts the point renderer's rgba32Float output to an 8-bit image.
    ///
    /// The values are sRGB-encoded to match the element renderers, which write
    /// into an sRGB framebuffer.
    private static func makeImage(fromRGBA32Float texture: MTLTexture) throws -> CGImage {
        #if os(macOS)
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
        #endif
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
                let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
                bytes[pixel * 4 + channel] = UInt8(encoded * 255 + 0.5)
            }
            bytes[pixel * 4 + 3] = 255
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(data: &bytes, width: texture.width, height: texture.height, bitsPerComponent: 8, bytesPerRow: texture.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue), let image = context.makeImage() else {
            throw MetalSprocketsError.resourceCreationFailure("Failed to convert rgba32Float texture to an image")
        }
        return image
    }
}

/// Hands the latest GPU counter sample from the command-buffer completion
/// handler (an arbitrary thread) to the frame loop.
private final class SampleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: GPUCounterSample?

    func set(_ newSample: GPUCounterSample) {
        lock.lock()
        sample = newSample
        lock.unlock()
    }

    func take() -> GPUCounterSample? {
        lock.lock()
        defer {
            sample = nil
            lock.unlock()
        }
        return sample
    }
}

#endif
