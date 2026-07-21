#if !arch(x86_64)

import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import Splats

/// Interactive PointSplat pipeline (RFC 0003): sort-free stochastic point
/// splatting with temporal accumulation, presented via a fullscreen blit.
///
/// Each frame is rendered at 1 sample per pixel and blended into a running
/// mean; callers should bump `resetAccumulation` inputs (camera/model
/// changes reset automatically via matrix comparison).
///
/// - Important: This renderer is **experimental**. Requires Apple9/Mac2
///   (64-bit atomics).
public struct PointSplatRenderPipeline: Element {
    private var splatCloud: GPUSplatCloud<SparkSplat>
    private var projectionMatrix: simd_float4x4
    private var modelMatrix: simd_float4x4
    private var cameraMatrix: simd_float4x4
    private var drawableSize: SIMD2<Float>
    private var frameIndex: UInt32

    @MSState private var resources: PointSplatResources?

    @MSEnvironment(\.device)
    private var environmentDevice

    private let resolveKernel: ComputeKernel
    private let blendKernel: ComputeKernel
    private let reprojectKernel: ComputeKernel
    private let blitVertexShader: VertexShader
    private let blitFragmentShader: FragmentShader

    private var supersampling: Int
    private var pointsPerThread: Int
    private var statistics: PointSplatStatistics?
    private var reprojection: Bool
    private var depthRange: ClosedRange<Float>

    /// - Parameters:
    ///   - splatCloud: The splat cloud to render.
    ///   - projectionMatrix: The camera projection matrix.
    ///   - modelMatrix: The scene-level model transform.
    ///   - cameraMatrix: The camera (view-to-world) matrix.
    ///   - drawableSize: The render target size in pixels.
    ///   - frameIndex: A monotonically increasing frame counter, used to vary the
    ///     stochastic sampling pattern each frame.
    ///   - depthRange: view-space range for the framebuffer's 28-bit
    ///     fixed-point depth quantization and the near cull. Should match the
    ///     projection's clip range; reversed-infinite-Z callers must supply a
    ///     finite far for quantization purposes.
    ///   - supersampling: Framebuffer supersampling factor. Clamped to at least 1.
    ///   - pointsPerThread: Number of points each compute thread splats. Clamped to at least 1.
    ///   - reprojection: Whether the previous frame's accumulation is reprojected
    ///     when the camera moves, reducing convergence noise.
    ///   - statistics: Optional collector for per-frame render statistics.
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, frameIndex: UInt32, depthRange: ClosedRange<Float> = 0.2...200.0, supersampling: Int = 2, pointsPerThread: Int = 4, reprojection: Bool = true, statistics: PointSplatStatistics? = nil) throws {
        self.depthRange = depthRange
        self.supersampling = max(supersampling, 1)
        self.pointsPerThread = max(pointsPerThread, 1)
        self.reprojection = reprojection
        self.statistics = statistics
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.frameIndex = frameIndex

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        let renderLibrary = shaderLibrary.namespaced("PointSplatRender")
        resolveKernel = try renderLibrary.function(named: "pointSplatResolve", type: ComputeKernel.self)
        reprojectKernel = try renderLibrary.function(named: "pointSplatReproject", type: ComputeKernel.self)
        blendKernel = try shaderLibrary.namespaced("TemporalAccumulationShader").function(named: "blend", type: ComputeKernel.self)
        let blitLibrary = shaderLibrary.namespaced("BlitShader")
        blitVertexShader = try blitLibrary.function(named: "vertex_main", type: VertexShader.self)
        // The accumulation texture holds sRGB-encoded splat values (the paper
        // averages in sRGB); linearize so the sRGB drawable's store encode
        // round-trips instead of double-encoding (#68).
        var blitConstants = FunctionConstants()
        blitConstants["convert_srgb_to_linear"] = .bool(true)
        blitFragmentShader = try blitLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: blitConstants)
    }

    /// `@MSState` persists resources across body evaluations, so a splat
    /// cloud swap (e.g. switching models in the demo) can outgrow the counts
    /// buffer and distributor before `.onChange` fires. Validate eagerly.
    ///
    /// Resources are created lazily here (not in `init`) so they can be
    /// allocated on the device MetalSprockets publishes via the environment
    /// rather than a freshly created system-default device (#83).
    private func validatedResources() throws -> PointSplatResources {
        guard let device = environmentDevice else {
            throw MetalSprocketsError.missingEnvironment(\.device)
        }
        let width = max(Int(drawableSize.x), 1)
        let height = max(Int(drawableSize.y), 1)
        if let resources, resources.device === device, resources.splatCount == splatCloud.count, resources.width == width, resources.height == height, resources.supersampling == supersampling, resources.pointsPerThread == pointsPerThread {
            return resources
        }
        let newResources = try PointSplatResources(device: device, drawableSize: drawableSize, splatCount: splatCloud.count, supersampling: supersampling, pointsPerThread: pointsPerThread)
        resources = newResources
        return newResources
    }

    public var body: some Element {
        get throws {
            let resources = try validatedResources()
            let width = resources.width
            let height = resources.height
            let bufferWidth = width * supersampling
            let bufferHeight = height * supersampling
            let uniforms = PointSplatUniforms(
                modelMatrix: modelMatrix,
                viewMatrix: cameraMatrix.inverse,
                projectionMatrix: projectionMatrix,
                drawableSize: SIMD2<Float>(Float(bufferWidth), Float(bufferHeight)),
                nearPlane: depthRange.lowerBound,
                farPlane: depthRange.upperBound,
                splatCount: UInt32(splatCloud.count),
                frameSeed: frameIndex,
                capacity: UInt32(resources.distributor.capacity),
                supersampling: UInt32(supersampling),
                pointsPerThread: UInt32(pointsPerThread),
                cameraPosition: SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z),
                shDegree: UInt32(splatCloud.shCoefficients != nil ? splatCloud.shDegree : 0),
                occlusionPhase: 0,
                pyramidLevels: UInt32(resources.pyramidLevels)
            )
            let shBuffer = splatCloud.shCoefficients?.unsafeMTLBuffer ?? resources.dummySHBuffer
            // Running mean: weight the new frame by 1/(n+1); camera or model
            // motion reprojects history (#73) or, with reprojection disabled
            // (#74), hard-resets so motion shows raw 1-SPP noise.
            let accumulation = resources.nextAccumulationStep(frameIndex: frameIndex, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix, projectionMatrix: projectionMatrix, allowReprojection: reprojection)
            try ComputePass(label: "PointSplat") {
                try ComputePipeline(computeKernel: resolveKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        .parameter("framebuffer", buffer: resources.framebuffer)
                        .parameter("uniforms", value: uniforms)
                        .parameter("outTexture", texture: resources.resolveTexture)
                }
                // The whole frame up to the resolve is raw-encoded: the splat
                // dispatches are indirect (GPU-side totals) and the two-phase
                // occlusion flow re-runs the workload distribution mid-frame,
                // neither of which MetalSprockets elements support.
                .onWorkloadEnter { [splatCloud, statistics, pointsPerThread, frameIndex] environmentValues in
                    guard let encoder = environmentValues.computeCommandEncoder else {
                        preconditionFailure("No compute command encoder found.")
                    }
                    // Publish the previous frame's per-phase totals before
                    // encoding overwrites them.
                    if let statistics {
                        let stats = resources.lastFrameStats
                        statistics.pointCount = (stats.phase1Used + stats.phase2Used) * pointsPerThread
                        statistics.pointDemand = (stats.phase1Demand + stats.phase2Demand) * pointsPerThread
                        statistics.pointBudget = resources.distributor.capacity * pointsPerThread
                    }
                    try resources.encodeFrame(encoder: encoder, uniforms: uniforms, splats: splatCloud.splats.unsafeMTLBuffer, shBuffer: shBuffer, seed: frameIndex)
                }
                if let previousViewProjection = accumulation.reprojectFrom {
                    // Camera moved: warp + clamp history instead of resetting
                    // to a single noisy frame (paper Sec. 3.6).
                    try ComputePipeline(computeKernel: reprojectKernel) {
                        try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                            .parameter("framebuffer", buffer: resources.framebuffer)
                            .parameter("uniforms", value: uniforms)
                            .parameter("cameraToWorld", value: cameraMatrix)
                            .parameter("previousViewProjection", value: previousViewProjection)
                            .parameter("currentFrame", texture: resources.resolveTexture)
                            .parameter("history", texture: accumulation.input)
                            .parameter("outTexture", texture: accumulation.output)
                    }
                } else {
                    try ComputePipeline(computeKernel: blendKernel) {
                        try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                            .parameter("currentFrame", texture: resources.resolveTexture)
                            .parameter("accumulationTexture", texture: accumulation.input)
                            .parameter("outputTexture", texture: accumulation.output)
                            .parameter("blendFactor", value: accumulation.blendFactor)
                    }
                }
            }
            try RenderPass {
                try RenderPipeline(vertexShader: blitVertexShader, fragmentShader: blitFragmentShader) {
                    Draw { commandEncoder in
                        commandEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                    .parameter("texture", texture: accumulation.output)
                }
            }
        }
    }
}

/// Live PointSplat workload numbers, updated once per frame from the
/// previous frame's GPU-written totals. Poll (rather than observe) from UI.
public final class PointSplatStatistics: @unchecked Sendable {
    /// Points splatted last frame (after any over-budget scaling).
    public var pointCount: Int = 0
    /// Raw point demand last frame; exceeding the budget means splats are
    /// being thinned proportionally.
    public var pointDemand: Int = 0
    public var pointBudget: Int = 0

    public init() {
        // No stored configuration; all fields start at zero.
    }
}

/// Per-drawable-size GPU resources and frame encoding shared by
/// ``PointSplatRenderPipeline`` (live) and ``PointSplatRenderer`` (offscreen).
final class PointSplatResources {
    let device: MTLDevice
    let backgroundColor: SIMD3<Float>
    let width: Int
    let height: Int
    let supersampling: Int
    let pointsPerThread: Int
    let framebuffer: MTLBuffer
    let counts: MTLBuffer
    let colors: MTLBuffer
    let dummySHBuffer: MTLBuffer
    let renderedMask: MTLBuffer
    /// Four uint32s: phase-1 [used, demand], phase-2 [used, demand], all in
    /// threads, copied from the distributor's totals on the GPU timeline.
    let statsBuffer: MTLBuffer
    private let zeroTotals: MTLBuffer
    let splatCount: Int
    /// Gaussians per hierarchical-culling group (#75); must match
    /// GROUP_SIZE in PointSplatRender.metal.
    static let groupSize = 256
    let groupCount: Int
    /// Two float4s (min, max) per group: model-space AABB expanded by 3
    /// sigma of each Gaussian's largest scale. Computed once per splat
    /// buffer on the GPU.
    private let groupBounds: MTLBuffer
    private let visibleGroups: MTLBuffer
    private let visibleGroupCount: MTLBuffer
    private let groupDispatchArgs: MTLBuffer
    /// Splat buffer the group AABBs were computed from; recompute on change.
    private var boundsSourceBuffer: ObjectIdentifier?
    let distributor: PointSplatWorkloadDistributor
    let resolveTexture: MTLTexture
    /// Hierarchical depth pyramid (max-depth mips) for occlusion culling.
    let depthPyramid: MTLTexture
    let pyramidLevels: Int
    private let pyramidLevelViews: [MTLTexture]
    private var hasDepthHistory = false

    private let clearPipelineState: MTLComputePipelineState
    private let groupBoundsPipelineState: MTLComputePipelineState
    private let clearCountsPipelineState: MTLComputePipelineState
    private let groupCullPipelineState: MTLComputePipelineState
    private let groupDispatchArgsPipelineState: MTLComputePipelineState
    private let preprocessPipelineState: MTLComputePipelineState
    private let splatPipelineState: MTLComputePipelineState
    private let resolvePipelineState: MTLComputePipelineState
    private let depthExtractPipelineState: MTLComputePipelineState
    private let depthDownsamplePipelineState: MTLComputePipelineState
    private let copyTotalsPipelineState: MTLComputePipelineState

    private let accumulationTextures: [MTLTexture]
    private(set) var accumulatedFrames: Int = 0
    private var frameParity: Int = 0
    private var lastCameraMatrix: simd_float4x4?
    private var lastModelMatrix: simd_float4x4?
    private var lastProjectionMatrix: simd_float4x4?
    private var lastAccumulationFrameIndex: UInt32?
    private var lastAccumulationStep: AccumulationStep?

    /// Far depth + packed background color: any splatted point wins the min.
    var clearValue: UInt64 {
        (UInt64(GPS_DEPTH_MAX) << UInt64(GPS_DEPTH_SHIFT)) | gps_pack_color(backgroundColor.x, backgroundColor.y, backgroundColor.z)
    }

    struct FrameStats {
        var phase1Used: Int
        var phase1Demand: Int
        var phase2Used: Int
        var phase2Demand: Int
    }

    /// Per-phase thread totals from the last completed frame.
    var lastFrameStats: FrameStats {
        let pointer = statsBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
        return FrameStats(phase1Used: Int(pointer[0]), phase1Demand: Int(pointer[1]), phase2Used: Int(pointer[2]), phase2Demand: Int(pointer[3]))
    }

    init(device: MTLDevice, drawableSize: SIMD2<Float>, splatCount: Int, supersampling: Int, pointsPerThread: Int, backgroundColor: SIMD3<Float> = .zero) throws {
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            throw PointSplatRenderer.RendererError.unsupportedDevice
        }
        self.device = device
        self.backgroundColor = backgroundColor
        width = max(Int(drawableSize.x), 1)
        height = max(Int(drawableSize.y), 1)
        self.supersampling = supersampling
        self.pointsPerThread = pointsPerThread
        let pixelCount = width * height * supersampling * supersampling

        guard let framebuffer = device.makeBuffer(length: MemoryLayout<UInt64>.stride * pixelCount, options: .storageModePrivate),
              let counts = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(splatCount, 1), options: .storageModePrivate),
              let colors = device.makeBuffer(length: MemoryLayout<UInt64>.stride * max(splatCount, 1), options: .storageModePrivate),
              let dummySHBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModePrivate),
              let renderedMask = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(splatCount, 1), options: .storageModePrivate),
              let statsBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 4, options: .storageModeShared),
              let zeroTotals = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 2, options: .storageModeShared) else {
            throw PointSplatRenderer.RendererError.bufferAllocationFailed
        }
        let groupCount = (max(splatCount, 1) + Self.groupSize - 1) / Self.groupSize
        self.groupCount = groupCount
        guard let groupBounds = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * 2 * groupCount, options: .storageModePrivate),
              let visibleGroups = device.makeBuffer(length: MemoryLayout<UInt32>.stride * groupCount, options: .storageModePrivate),
              let visibleGroupCount = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModePrivate),
              let groupDispatchArgs = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 4, options: .storageModePrivate) else {
            throw PointSplatRenderer.RendererError.bufferAllocationFailed
        }
        groupBounds.label = "PointSplat group bounds"
        visibleGroups.label = "PointSplat visible groups"
        visibleGroupCount.label = "PointSplat visible group count"
        groupDispatchArgs.label = "PointSplat group dispatch args"
        self.groupBounds = groupBounds
        self.visibleGroups = visibleGroups
        self.visibleGroupCount = visibleGroupCount
        self.groupDispatchArgs = groupDispatchArgs
        framebuffer.label = "PointSplat framebuffer64"
        counts.label = "PointSplat per-splat counts"
        colors.label = "PointSplat colors"
        dummySHBuffer.label = "PointSplat dummy SH"
        renderedMask.label = "PointSplat rendered mask"
        statsBuffer.label = "PointSplat stats"
        zeroTotals.label = "PointSplat zero totals"
        self.framebuffer = framebuffer
        self.counts = counts
        self.colors = colors
        self.dummySHBuffer = dummySHBuffer
        self.renderedMask = renderedMask
        self.statsBuffer = statsBuffer
        self.zeroTotals = zeroTotals
        self.splatCount = splatCount
        // Point budget scales with the supersampled framebuffer size.
        distributor = try PointSplatWorkloadDistributor(device: device, capacity: PointSplatWorkloadDistributor.capacity(forSupersampledPixels: pixelCount, pointsPerThread: pointsPerThread), maxSplats: splatCount)

        let library = try device.makeDefaultLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw PointSplatRenderer.RendererError.functionNotFound(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        clearPipelineState = try pipeline("PointSplatRender::pointSplatClear")
        groupBoundsPipelineState = try pipeline("PointSplatRender::pointSplatGroupBounds")
        clearCountsPipelineState = try pipeline("PointSplatRender::pointSplatClearCounts")
        groupCullPipelineState = try pipeline("PointSplatRender::pointSplatGroupCull")
        groupDispatchArgsPipelineState = try pipeline("PointSplatRender::pointSplatGroupDispatchArgs")
        preprocessPipelineState = try pipeline("PointSplatRender::pointSplatPreprocess")
        splatPipelineState = try pipeline("PointSplatRender::pointSplatSplat")
        resolvePipelineState = try pipeline("PointSplatRender::pointSplatResolve")
        depthExtractPipelineState = try pipeline("PointSplatRender::pointSplatDepthExtract")
        depthDownsamplePipelineState = try pipeline("PointSplatRender::pointSplatDepthDownsample")
        copyTotalsPipelineState = try pipeline("PointSplatWorkload::workloadCopyTotals")

        // Depth pyramid at native resolution with a full max-depth mip chain.
        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        pyramidLevels = levels
        let pyramidDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: true)
        pyramidDescriptor.mipmapLevelCount = levels
        pyramidDescriptor.usage = [.shaderRead, .shaderWrite]
        pyramidDescriptor.storageMode = .private
        guard let depthPyramid = device.makeTexture(descriptor: pyramidDescriptor) else {
            throw PointSplatRenderer.RendererError.textureAllocationFailed
        }
        depthPyramid.label = "PointSplat depth pyramid"
        self.depthPyramid = depthPyramid
        pyramidLevelViews = try (0..<levels).map { level in
            guard let view = depthPyramid.makeTextureView(pixelFormat: .r32Float, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1) else {
                throw PointSplatRenderer.RendererError.textureAllocationFailed
            }
            return view
        }

        let textureWidth = width
        let textureHeight = height
        func makeTexture(label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: textureWidth, height: textureHeight, mipmapped: false)
            descriptor.usage = [.shaderWrite, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw PointSplatRenderer.RendererError.textureAllocationFailed
            }
            texture.label = label
            return texture
        }
        resolveTexture = try makeTexture(label: "PointSplat resolve")
        accumulationTextures = [try makeTexture(label: "PointSplat accumulation A"), try makeTexture(label: "PointSplat accumulation B")]
    }

    /// Encodes one full PointSplat frame up to (not including) the resolve:
    /// clear, phase-1 preprocess/distribute/splat, depth pyramid build, and
    /// — when a pyramid from a previous frame exists — the paper's phase 2
    /// (re-testing phase-1-culled Gaussians against the fresh pyramid so
    /// stale-depth culling can never lose geometry).
    func encodeFrame(encoder: MTLComputeCommandEncoder, uniforms: PointSplatUniforms, splats: MTLBuffer, shBuffer: MTLBuffer, seed: UInt32) throws {
        let blockThreads = MTLSize(width: 256, height: 1, depth: 1)
        let pixelCount = width * height * supersampling * supersampling
        var clearValueCopy = clearValue
        var pixelCountValue = UInt32(pixelCount)

        encoder.setComputePipelineState(clearPipelineState)
        encoder.setBuffer(framebuffer, offset: 0, index: 0)
        encoder.setBytes(&clearValueCopy, length: MemoryLayout<UInt64>.stride, index: 1)
        encoder.setBytes(&pixelCountValue, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: pixelCount, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)

        // Group AABBs are a pure function of the splat buffer; recompute
        // only when it changes (#75).
        if boundsSourceBuffer != ObjectIdentifier(splats) {
            var splatCountValue = UInt32(splatCount)
            encoder.setComputePipelineState(groupBoundsPipelineState)
            encoder.setBuffer(splats, offset: 0, index: 0)
            encoder.setBuffer(groupBounds, offset: 0, index: 1)
            encoder.setBytes(&splatCountValue, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: groupCount, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
            boundsSourceBuffer = ObjectIdentifier(splats)
        }

        var phase1 = uniforms
        phase1.occlusionPhase = hasDepthHistory ? 1 : 0
        try encodePhase(encoder: encoder, uniforms: phase1, splats: splats, shBuffer: shBuffer, seed: seed, statsOffset: 0)
        encodePyramidBuild(encoder: encoder, uniforms: uniforms)

        if phase1.occlusionPhase == 1 {
            var phase2 = uniforms
            phase2.occlusionPhase = 2
            try encodePhase(encoder: encoder, uniforms: phase2, splats: splats, shBuffer: shBuffer, seed: seed &+ 0x9E37_79B9, statsOffset: 2)
            // Refresh the pyramid with phase-2 contributions for next frame.
            encodePyramidBuild(encoder: encoder, uniforms: uniforms)
        } else {
            // No phase 2 this frame: zero its stats slots.
            var statsOffset = UInt32(2)
            encoder.setComputePipelineState(copyTotalsPipelineState)
            encoder.setBuffer(zeroTotals, offset: 0, index: 0)
            encoder.setBuffer(statsBuffer, offset: 0, index: 1)
            encoder.setBytes(&statsOffset, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreads(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))
        }
        hasDepthHistory = true
    }

    /// Box-filters the supersampled framebuffer into `outTexture`.
    func encodeResolve(encoder: MTLComputeCommandEncoder, uniforms: PointSplatUniforms, outTexture: MTLTexture) {
        var uniformsCopy = uniforms
        encoder.setComputePipelineState(resolvePipelineState)
        encoder.setBuffer(framebuffer, offset: 0, index: 0)
        encoder.setBytes(&uniformsCopy, length: MemoryLayout<PointSplatUniforms>.stride, index: 1)
        encoder.setTexture(outTexture, index: 0)
        encoder.dispatchThreads(MTLSize(width: outTexture.width, height: outTexture.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    /// One preprocess -> distribute -> splat round for the given phase.
    private func encodePhase(encoder: MTLComputeCommandEncoder, uniforms: PointSplatUniforms, splats: MTLBuffer, shBuffer: MTLBuffer, seed: UInt32, statsOffset: Int) throws {
        let blockThreads = MTLSize(width: 256, height: 1, depth: 1)
        var uniformsCopy = uniforms
        var groupCountValue = UInt32(groupCount)

        // Reset counts/mask/visible-group counter, cull whole groups against
        // the frustum and depth pyramid, then run the per-Gaussian
        // preprocess only for surviving groups (#75).
        encoder.setComputePipelineState(clearCountsPipelineState)
        encoder.setBuffer(counts, offset: 0, index: 0)
        encoder.setBuffer(renderedMask, offset: 0, index: 1)
        encoder.setBuffer(visibleGroupCount, offset: 0, index: 2)
        encoder.setBytes(&uniformsCopy, length: MemoryLayout<PointSplatUniforms>.stride, index: 3)
        encoder.dispatchThreads(MTLSize(width: max(splatCount, 1), height: 1, depth: 1), threadsPerThreadgroup: blockThreads)

        encoder.setComputePipelineState(groupCullPipelineState)
        encoder.setBuffer(groupBounds, offset: 0, index: 0)
        encoder.setBuffer(visibleGroups, offset: 0, index: 1)
        encoder.setBuffer(visibleGroupCount, offset: 0, index: 2)
        encoder.setBytes(&uniformsCopy, length: MemoryLayout<PointSplatUniforms>.stride, index: 3)
        encoder.setBytes(&groupCountValue, length: MemoryLayout<UInt32>.stride, index: 4)
        encoder.setTexture(depthPyramid, index: 0)
        encoder.dispatchThreads(MTLSize(width: groupCount, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)

        encoder.setComputePipelineState(groupDispatchArgsPipelineState)
        encoder.setBuffer(visibleGroupCount, offset: 0, index: 0)
        encoder.setBuffer(groupDispatchArgs, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        encoder.setComputePipelineState(preprocessPipelineState)
        encoder.setBuffer(splats, offset: 0, index: 0)
        encoder.setBuffer(counts, offset: 0, index: 1)
        encoder.setBytes(&uniformsCopy, length: MemoryLayout<PointSplatUniforms>.stride, index: 2)
        encoder.setBuffer(shBuffer, offset: 0, index: 3)
        encoder.setBuffer(colors, offset: 0, index: 4)
        encoder.setBuffer(renderedMask, offset: 0, index: 5)
        encoder.setBuffer(visibleGroups, offset: 0, index: 6)
        encoder.setTexture(depthPyramid, index: 0)
        encoder.dispatchThreadgroups(indirectBuffer: groupDispatchArgs, indirectBufferOffset: 0, threadsPerThreadgroup: blockThreads)

        try distributor.encode(encoder: encoder, counts: counts, count: splatCount, seed: seed)

        var statsOffsetValue = UInt32(statsOffset)
        encoder.setComputePipelineState(copyTotalsPipelineState)
        encoder.setBuffer(distributor.totalsBuffer, offset: 0, index: 0)
        encoder.setBuffer(statsBuffer, offset: 0, index: 1)
        encoder.setBytes(&statsOffsetValue, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))

        encoder.setComputePipelineState(splatPipelineState)
        encoder.setBuffer(splats, offset: 0, index: 0)
        encoder.setBuffer(distributor.indicesBuffer, offset: 0, index: 1)
        encoder.setBuffer(framebuffer, offset: 0, index: 2)
        encoder.setBytes(&uniformsCopy, length: MemoryLayout<PointSplatUniforms>.stride, index: 3)
        encoder.setBuffer(distributor.totalsBuffer, offset: 0, index: 4)
        encoder.setBuffer(framebuffer, offset: 0, index: 5)
        encoder.setBuffer(colors, offset: 0, index: 6)
        encoder.dispatchThreadgroups(indirectBuffer: distributor.dispatchArgsBuffer, indirectBufferOffset: 0, threadsPerThreadgroup: blockThreads)
    }

    /// Extracts native-resolution max depth from the framebuffer and builds
    /// the max-depth mip chain.
    private func encodePyramidBuild(encoder: MTLComputeCommandEncoder, uniforms: PointSplatUniforms) {
        var uniformsCopy = uniforms
        encoder.setComputePipelineState(depthExtractPipelineState)
        encoder.setBuffer(framebuffer, offset: 0, index: 0)
        encoder.setBytes(&uniformsCopy, length: MemoryLayout<PointSplatUniforms>.stride, index: 1)
        encoder.setTexture(pyramidLevelViews[0], index: 0)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))

        encoder.setComputePipelineState(depthDownsamplePipelineState)
        for level in 1..<pyramidLevels {
            let destination = pyramidLevelViews[level]
            encoder.setTexture(pyramidLevelViews[level - 1], index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
    }

    struct AccumulationStep {
        var input: MTLTexture
        var output: MTLTexture
        var blendFactor: Float
        /// When set, the camera moved: reproject history from this previous
        /// view-projection instead of running-mean blending.
        var reprojectFrom: simd_float4x4?
    }

    /// Advances the ping-pong textures and returns this frame's blend
    /// inputs. A static view continues the running mean; camera or
    /// projection motion switches to reprojection against the previous
    /// view-projection (model changes still hard-reset — reprojection can't
    /// warp content change).
    ///
    /// Idempotent per `frameIndex`: `body` can be evaluated multiple times
    /// per frame (diffing/re-expansion), so repeat calls for the same frame
    /// return the cached step instead of advancing the ping-pong parity and
    /// accumulation count again (#82).
    func nextAccumulationStep(frameIndex: UInt32, cameraMatrix: simd_float4x4, modelMatrix: simd_float4x4, projectionMatrix: simd_float4x4, allowReprojection: Bool = true) -> AccumulationStep {
        if frameIndex == lastAccumulationFrameIndex, let lastAccumulationStep {
            return lastAccumulationStep
        }
        let viewMoved = lastCameraMatrix != cameraMatrix || lastProjectionMatrix != projectionMatrix
        let modelChanged = lastModelMatrix != modelMatrix
        let previousViewProjection: simd_float4x4? = if let lastCameraMatrix, let lastProjectionMatrix {
            lastProjectionMatrix * lastCameraMatrix.inverse
        } else {
            nil
        }

        var reprojectFrom: simd_float4x4?
        if modelChanged {
            accumulatedFrames = 0
        } else if viewMoved {
            if allowReprojection, let previousViewProjection, accumulatedFrames > 0 {
                reprojectFrom = previousViewProjection
                // Resume post-motion convergence from a moderate weight
                // rather than trusting warped history as a long average.
                accumulatedFrames = min(accumulatedFrames, 9)
            } else {
                accumulatedFrames = 0
            }
        }
        lastCameraMatrix = cameraMatrix
        lastModelMatrix = modelMatrix
        lastProjectionMatrix = projectionMatrix

        let step = AccumulationStep(
            input: accumulationTextures[frameParity],
            output: accumulationTextures[(frameParity + 1) % 2],
            blendFactor: 1.0 / Float(accumulatedFrames + 1),
            reprojectFrom: reprojectFrom
        )
        accumulatedFrames += 1
        frameParity = (frameParity + 1) % 2
        lastAccumulationFrameIndex = frameIndex
        lastAccumulationStep = step
        return step
    }
}

#endif
