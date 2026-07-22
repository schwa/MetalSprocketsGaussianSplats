#if !arch(x86_64)

import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import Splats

internal import os

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

    /// Rendering options for ``PointSplatRenderPipeline`` (#101).
    public struct Configuration {
        /// View-space range for the framebuffer's 28-bit fixed-point depth
        /// quantization and the near cull. Should match the projection's clip
        /// range; reversed-infinite-Z callers must supply a finite far for
        /// quantization purposes.
        public var depthRange: ClosedRange<Float>
        /// Framebuffer supersampling factor. Clamped to at least 1.
        public var supersampling: Int
        /// Number of points each compute thread splats. Clamped to at least 1.
        /// Default is 16: on Apple GPUs the bench sweep measured no PSNR cost
        /// for K up to 16 at fixed S, and K = 16 is ~2x faster than the
        /// paper's K = 4 (issue #76).
        public var pointsPerThread: Int
        /// Whether the previous frame's accumulation is reprojected when the
        /// camera moves, reducing convergence noise.
        public var reprojection: Bool
        /// Optional collector for per-frame render statistics.
        public var statistics: PointSplatStatistics?

        public init(depthRange: ClosedRange<Float> = 0.2...200.0, supersampling: Int = 2, pointsPerThread: Int = 16, reprojection: Bool = true, statistics: PointSplatStatistics? = nil) {
            self.depthRange = depthRange
            self.supersampling = supersampling
            self.pointsPerThread = pointsPerThread
            self.reprojection = reprojection
            self.statistics = statistics
        }
    }

    /// - Parameters:
    ///   - splatCloud: The splat cloud to render.
    ///   - projectionMatrix: The camera projection matrix.
    ///   - modelMatrix: The scene-level model transform.
    ///   - cameraMatrix: The camera (view-to-world) matrix.
    ///   - drawableSize: The render target size in pixels.
    ///   - frameIndex: A monotonically increasing frame counter, used to vary the
    ///     stochastic sampling pattern each frame.
    ///   - configuration: Rendering options (depth range, supersampling,
    ///     points per thread, reprojection, statistics).
    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, frameIndex: UInt32, configuration: Configuration = Configuration()) throws {
        self.depthRange = configuration.depthRange
        self.supersampling = max(configuration.supersampling, 1)
        self.pointsPerThread = max(configuration.pointsPerThread, 1)
        self.reprojection = configuration.reprojection
        self.statistics = configuration.statistics
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
            // Running mean: weight the new frame by 1/(n+1); camera or model
            // motion reprojects history (#73) or, with reprojection disabled
            // (#74), hard-resets so motion shows raw 1-SPP noise.
            let accumulation = resources.nextAccumulationStep(frameIndex: frameIndex, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix, projectionMatrix: projectionMatrix, allowReprojection: reprojection)
            // Temporal point reuse engages on motion frames (RFC 0005 §4):
            // seed points cover half the budget, fresh sampling the rest.
            let reuseFactor: Float = accumulation.reprojectFrom != nil ? 0.5 : 0
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
                pyramidLevels: UInt32(resources.pyramidLevels),
                packedSplats: 0,
                reuseFactor: reuseFactor
            )
            let shBuffer = splatCloud.shCoefficients?.unsafeMTLBuffer ?? resources.dummySHBuffer
            let seedReprojection: PointSplatResources.SeedReprojection? =
                if reuseFactor > 0, let previousCameraMatrix = accumulation.previousCameraMatrix, let previousProjectionMatrix = accumulation.previousProjectionMatrix {
                    PointSplatResources.SeedReprojection(previousCameraToWorld: previousCameraMatrix, previousInverseProjection: previousProjectionMatrix.inverse)
                } else {
                    nil
                }
            let plan = resources.framePlan(planKey: UInt64(frameIndex), splats: splatCloud.splats.unsafeMTLBuffer)
            try ComputePass(label: "PointSplat") {
                try resources.frameElements(uniforms: uniforms, splats: splatCloud.splats.unsafeMTLBuffer, shBuffer: shBuffer, seed: frameIndex, packedBounds: GPSPackedSplatBounds(), plan: plan, seedReprojection: seedReprojection)
                try ComputePipeline(computeKernel: resolveKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        .parameter("framebuffer", buffer: resources.framebuffer)
                        .parameter("uniforms", value: uniforms)
                        .parameter("outTexture", texture: resources.resolveTexture)
                }
                // Publish the previous completed frame's per-phase totals.
                .onWorkloadEnter { [statistics, pointsPerThread] _ in
                    if let statistics {
                        let stats = resources.lastFrameStats
                        statistics.pointCount = (stats.phase1Used + stats.phase2Used) * pointsPerThread
                        statistics.pointDemand = (stats.phase1Demand + stats.phase2Demand) * pointsPerThread
                        statistics.pointBudget = resources.distributor.capacity * pointsPerThread
                    }
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
public final class PointSplatStatistics: Sendable {
    private struct State {
        var pointCount = 0
        var pointDemand = 0
        var pointBudget = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Points splatted last frame (after any over-budget scaling).
    public var pointCount: Int {
        get { state.withLock(\.pointCount) }
        set { state.withLock { $0.pointCount = newValue } }
    }
    /// Raw point demand last frame; exceeding the budget means splats are
    /// being thinned proportionally.
    public var pointDemand: Int {
        get { state.withLock(\.pointDemand) }
        set { state.withLock { $0.pointDemand = newValue } }
    }
    public var pointBudget: Int {
        get { state.withLock(\.pointBudget) }
        set { state.withLock { $0.pointBudget = newValue } }
    }

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

    private let clearKernel: ComputeKernel
    private let groupBoundsKernel: ComputeKernel
    private let clearCountsKernel: ComputeKernel
    private let groupCullKernel: ComputeKernel
    private let groupDispatchArgsKernel: ComputeKernel
    private let preprocessKernel: ComputeKernel
    private let splatKernel: ComputeKernel
    private let resolveKernel: ComputeKernel
    private let depthExtractKernel: ComputeKernel
    private let seedReprojectKernel: ComputeKernel
    private let depthDownsampleKernel: ComputeKernel
    private let copyTotalsKernel: ComputeKernel

    private let accumulationTextures: [MTLTexture]
    private(set) var accumulatedFrames: Int = 0
    private var frameParity: Int = 0
    private var lastCameraMatrix: simd_float4x4?
    private var lastModelMatrix: simd_float4x4?
    private var lastProjectionMatrix: simd_float4x4?
    private var lastAccumulationFrameIndex: UInt32?
    private var lastAccumulationStep: AccumulationStep?
    private var lastPlanKey: UInt64?
    private var lastPlan: FramePlan?

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
            throw PointSplatError.unsupportedDevice
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
            throw PointSplatError.bufferAllocationFailed
        }
        let groupCount = (max(splatCount, 1) + Self.groupSize - 1) / Self.groupSize
        self.groupCount = groupCount
        guard let groupBounds = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * 2 * groupCount, options: .storageModePrivate),
              let visibleGroups = device.makeBuffer(length: MemoryLayout<UInt32>.stride * groupCount, options: .storageModePrivate),
              let visibleGroupCount = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModePrivate),
              let groupDispatchArgs = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 4, options: .storageModePrivate) else {
            throw PointSplatError.bufferAllocationFailed
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

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        let renderLibrary = shaderLibrary.namespaced("PointSplatRender")
        clearKernel = try renderLibrary.function(named: "pointSplatClear", type: ComputeKernel.self)
        groupBoundsKernel = try renderLibrary.function(named: "pointSplatGroupBounds", type: ComputeKernel.self)
        clearCountsKernel = try renderLibrary.function(named: "pointSplatClearCounts", type: ComputeKernel.self)
        groupCullKernel = try renderLibrary.function(named: "pointSplatGroupCull", type: ComputeKernel.self)
        groupDispatchArgsKernel = try renderLibrary.function(named: "pointSplatGroupDispatchArgs", type: ComputeKernel.self)
        preprocessKernel = try renderLibrary.function(named: "pointSplatPreprocess", type: ComputeKernel.self)
        splatKernel = try renderLibrary.function(named: "pointSplatSplat", type: ComputeKernel.self)
        resolveKernel = try renderLibrary.function(named: "pointSplatResolve", type: ComputeKernel.self)
        depthExtractKernel = try renderLibrary.function(named: "pointSplatDepthExtract", type: ComputeKernel.self)
        seedReprojectKernel = try renderLibrary.function(named: "pointSplatSeedReproject", type: ComputeKernel.self)
        depthDownsampleKernel = try renderLibrary.function(named: "pointSplatDepthDownsample", type: ComputeKernel.self)
        copyTotalsKernel = try shaderLibrary.namespaced("PointSplatWorkload").function(named: "workloadCopyTotals", type: ComputeKernel.self)

        // Depth pyramid at native resolution with a full max-depth mip chain.
        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        pyramidLevels = levels
        let pyramidDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: true)
        pyramidDescriptor.mipmapLevelCount = levels
        pyramidDescriptor.usage = [.shaderRead, .shaderWrite]
        pyramidDescriptor.storageMode = .private
        guard let depthPyramid = device.makeTexture(descriptor: pyramidDescriptor) else {
            throw PointSplatError.textureAllocationFailed
        }
        depthPyramid.label = "PointSplat depth pyramid"
        self.depthPyramid = depthPyramid
        pyramidLevelViews = try (0..<levels).map { level in
            guard let view = depthPyramid.makeTextureView(pixelFormat: .r32Float, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1) else {
                throw PointSplatError.textureAllocationFailed
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
                throw PointSplatError.textureAllocationFailed
            }
            texture.label = label
            return texture
        }
        resolveTexture = try makeTexture(label: "PointSplat resolve")
        accumulationTextures = [try makeTexture(label: "PointSplat accumulation A"), try makeTexture(label: "PointSplat accumulation B")]
    }

    /// Per-frame element-tree decisions that also advance resources state
    /// (group-bounds cache, depth history). Idempotent per `planKey`: `body`
    /// can be evaluated multiple times per frame, so repeat calls for the
    /// same key return the cached plan instead of advancing state again.
    struct FramePlan {
        /// Recompute group AABBs: the splat buffer changed since the last
        /// frame (#75).
        var recomputeBounds: Bool
        /// Run the paper's two-phase occlusion flow: a depth pyramid from a
        /// previous frame exists.
        var occlusionPhase2: Bool
    }

    func framePlan(planKey: UInt64, splats: MTLBuffer) -> FramePlan {
        if planKey == lastPlanKey, let lastPlan {
            return lastPlan
        }
        let plan = FramePlan(recomputeBounds: boundsSourceBuffer != ObjectIdentifier(splats), occlusionPhase2: hasDepthHistory)
        boundsSourceBuffer = ObjectIdentifier(splats)
        hasDepthHistory = true
        lastPlanKey = planKey
        lastPlan = plan
        return plan
    }

    /// One full PointSplat frame up to (not including) the resolve, as
    /// compute elements for an enclosing ``ComputePass``: clear, phase-1
    /// preprocess/distribute/splat, depth pyramid build, and — when a
    /// pyramid from a previous frame exists — the paper's phase 2
    /// (re-testing phase-1-culled Gaussians against the fresh pyramid so
    /// stale-depth culling can never lose geometry).
    /// Reprojection inputs for temporal point reuse (RFC 0005 §4).
    struct SeedReprojection {
        var previousCameraToWorld: simd_float4x4
        var previousInverseProjection: simd_float4x4
    }

    func frameElements(uniforms: PointSplatUniforms, splats: MTLBuffer, shBuffer: MTLBuffer, seed: UInt32, packedBounds: GPSPackedSplatBounds = GPSPackedSplatBounds(), plan: FramePlan, seedReprojection: SeedReprojection? = nil) throws -> some Element {
        try distributor.validate(count: splatCount)
        let blockThreads = MTLSize(width: 256, height: 1, depth: 1)
        let pixelCount = width * height * supersampling * supersampling
        var phase1 = uniforms
        phase1.occlusionPhase = plan.occlusionPhase2 ? 1 : 0
        var phase2 = uniforms
        phase2.occlusionPhase = 2

        return try Group {
            try ComputePipeline(computeKernel: clearKernel) {
                try ComputeDispatch(threadsPerGrid: MTLSize(width: pixelCount, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                    .parameter("framebuffer", buffer: framebuffer)
                    .parameter("clearValue", value: clearValue)
                    .parameter("pixelCount", value: UInt32(pixelCount))
            }
            if let seedReprojection {
                // Seed the fresh framebuffer with last frame's depth-tested
                // surface before any fresh splats (RFC 0005 §4). Reads the
                // previous frame's resolve and depth pyramid level 0, both
                // still intact at this point.
                try ComputePipeline(computeKernel: seedReprojectKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        .parameter("framebuffer", buffer: framebuffer)
                        .parameter("uniforms", value: uniforms)
                        .parameter("previousCameraToWorld", value: seedReprojection.previousCameraToWorld)
                        .parameter("previousInverseProjection", value: seedReprojection.previousInverseProjection)
                        .parameter("previousResolve", texture: resolveTexture)
                        .parameter("previousDepth", texture: pyramidLevelViews[0])
                }
            }
            if plan.recomputeBounds {
                try ComputePipeline(computeKernel: groupBoundsKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: groupCount, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                        .parameter("splats", buffer: splats)
                        .parameter("bounds", buffer: groupBounds)
                        .parameter("splatCount", value: UInt32(splatCount))
                        .parameter("packedFlag", value: uniforms.packedSplats)
                        .parameter("packedBounds", value: packedBounds)
                }
            }
            try phaseElements(uniforms: phase1, splats: splats, shBuffer: shBuffer, seed: seed, statsOffset: 0, packedBounds: packedBounds)
            try pyramidElements(uniforms: uniforms)
            if plan.occlusionPhase2 {
                try phaseElements(uniforms: phase2, splats: splats, shBuffer: shBuffer, seed: seed &+ 0x9E37_79B9, statsOffset: 2, packedBounds: packedBounds)
                // Refresh the pyramid with phase-2 contributions for next frame.
                try pyramidElements(uniforms: uniforms)
            } else {
                // No phase 2 this frame: zero its stats slots.
                try ComputePipeline(computeKernel: copyTotalsKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))
                        .parameter("totals", buffer: zeroTotals)
                        .parameter("dst", buffer: statsBuffer)
                        .parameter("offset", value: UInt32(2))
                }
            }
        }
    }

    /// Box-filters the supersampled framebuffer into `outTexture`.
    func resolveElements(uniforms: PointSplatUniforms, outTexture: MTLTexture) throws -> some Element {
        try ComputePipeline(computeKernel: resolveKernel) {
            try ComputeDispatch(threadsPerGrid: MTLSize(width: outTexture.width, height: outTexture.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                .parameter("framebuffer", buffer: framebuffer)
                .parameter("uniforms", value: uniforms)
                .parameter("outTexture", texture: outTexture)
        }
    }

    /// One preprocess -> distribute -> splat round for the given phase.
    private func phaseElements(uniforms: PointSplatUniforms, splats: MTLBuffer, shBuffer: MTLBuffer, seed: UInt32, statsOffset: Int, packedBounds: GPSPackedSplatBounds) throws -> some Element {
        let blockThreads = MTLSize(width: 256, height: 1, depth: 1)
        let single = MTLSize(width: 1, height: 1, depth: 1)

        // Reset counts/mask/visible-group counter, cull whole groups against
        // the frustum and depth pyramid, then run the per-Gaussian
        // preprocess only for surviving groups (#75).
        return try Group {
            try ComputePipeline(computeKernel: clearCountsKernel) {
                try ComputeDispatch(threadsPerGrid: MTLSize(width: max(splatCount, 1), height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                    .parameter("counts", buffer: counts)
                    .parameter("renderedMask", buffer: renderedMask)
                    .parameter("visibleGroupCount", buffer: visibleGroupCount)
                    .parameter("uniforms", value: uniforms)
            }
            try ComputePipeline(computeKernel: groupCullKernel) {
                try ComputeDispatch(threadsPerGrid: MTLSize(width: groupCount, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                    .parameter("bounds", buffer: groupBounds)
                    .parameter("visibleGroups", buffer: visibleGroups)
                    .parameter("visibleGroupCount", buffer: visibleGroupCount)
                    .parameter("uniforms", value: uniforms)
                    .parameter("groupCount", value: UInt32(groupCount))
                    .parameter("depthPyramid", texture: depthPyramid)
            }
            try ComputePipeline(computeKernel: groupDispatchArgsKernel) {
                try ComputeDispatch(threadsPerGrid: single, threadsPerThreadgroup: single)
                    .parameter("visibleGroupCount", buffer: visibleGroupCount)
                    .parameter("args", buffer: groupDispatchArgs)
            }
            try ComputePipeline(computeKernel: preprocessKernel) {
                try ComputeDispatch(indirectBuffer: groupDispatchArgs, threadsPerThreadgroup: blockThreads)
                    .parameter("splats", buffer: splats)
                    .parameter("counts", buffer: counts)
                    .parameter("uniforms", value: uniforms)
                    .parameter("shCoefficients", buffer: shBuffer)
                    .parameter("colors", buffer: colors)
                    .parameter("renderedMask", buffer: renderedMask)
                    .parameter("visibleGroups", buffer: visibleGroups)
                    .parameter("packedBounds", value: packedBounds)
                    .parameter("depthPyramid", texture: depthPyramid)
            }
            try distributor.elements(counts: counts, count: splatCount, seed: seed)
            try ComputePipeline(computeKernel: copyTotalsKernel) {
                try ComputeDispatch(threadsPerGrid: MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))
                    .parameter("totals", buffer: distributor.totalsBuffer)
                    .parameter("dst", buffer: statsBuffer)
                    .parameter("offset", value: UInt32(statsOffset))
            }
            try ComputePipeline(computeKernel: splatKernel) {
                try ComputeDispatch(indirectBuffer: distributor.dispatchArgsBuffer, threadsPerThreadgroup: blockThreads)
                    .parameter("splats", buffer: splats)
                    .parameter("indices", buffer: distributor.indicesBuffer)
                    .parameter("framebuffer", buffer: framebuffer)
                    .parameter("uniforms", value: uniforms)
                    .parameter("totals", buffer: distributor.totalsBuffer)
                    .parameter("framebufferRead", buffer: framebuffer)
                    .parameter("colors", buffer: colors)
                    .parameter("packedBounds", value: packedBounds)
            }
        }
    }

    /// Extracts native-resolution max depth from the framebuffer and builds
    /// the max-depth mip chain.
    private func pyramidElements(uniforms: PointSplatUniforms) throws -> some Element {
        try Group {
            try ComputePipeline(computeKernel: depthExtractKernel) {
                try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    .parameter("framebuffer", buffer: framebuffer)
                    .parameter("uniforms", value: uniforms)
                    .parameter("outDepth", texture: pyramidLevelViews[0])
            }
            try ComputePipeline(computeKernel: depthDownsampleKernel) {
                ForEach(Array(1..<pyramidLevels), id: \.self) { [pyramidLevelViews] level in
                    let destination = pyramidLevelViews[level]
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: destination.width, height: destination.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        .parameter("src", texture: pyramidLevelViews[level - 1])
                        .parameter("dst", texture: destination)
                }
            }
        }
    }

    struct AccumulationStep {
        var input: MTLTexture
        var output: MTLTexture
        var blendFactor: Float
        /// When set, the camera moved: reproject history from this previous
        /// view-projection instead of running-mean blending.
        var reprojectFrom: simd_float4x4?
        /// Previous frame's camera/projection, for point-level seed
        /// reprojection (RFC 0005 §4). Set whenever `reprojectFrom` is.
        var previousCameraMatrix: simd_float4x4?
        var previousProjectionMatrix: simd_float4x4?
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
        var previousCamera: simd_float4x4?
        var previousProjection: simd_float4x4?
        if modelChanged {
            accumulatedFrames = 0
        } else if viewMoved {
            if allowReprojection, let previousViewProjection, accumulatedFrames > 0 {
                reprojectFrom = previousViewProjection
                previousCamera = lastCameraMatrix
                previousProjection = lastProjectionMatrix
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
            reprojectFrom: reprojectFrom,
            previousCameraMatrix: previousCamera,
            previousProjectionMatrix: previousProjection
        )
        accumulatedFrames += 1
        frameParity = (frameParity + 1) % 2
        lastAccumulationFrameIndex = frameIndex
        lastAccumulationStep = step
        return step
    }
}

#endif
