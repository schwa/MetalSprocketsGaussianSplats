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

    @MSState private var resources: PointSplatResources

    private let clearKernel: ComputeKernel
    private let preprocessKernel: ComputeKernel
    private let splatKernel: ComputeKernel
    private let resolveKernel: ComputeKernel
    private let blendKernel: ComputeKernel
    private let blitVertexShader: VertexShader
    private let blitFragmentShader: FragmentShader

    private var supersampling: Int
    private var pointsPerThread: Int

    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, frameIndex: UInt32, maxPointsPerFrame: Int = 4_000_000, supersampling: Int = 2, pointsPerThread: Int = 4) throws {
        self.supersampling = max(supersampling, 1)
        self.pointsPerThread = max(pointsPerThread, 1)
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.frameIndex = frameIndex

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        let renderLibrary = shaderLibrary.namespaced("PointSplatRender")
        clearKernel = try renderLibrary.function(named: "pointSplatClear", type: ComputeKernel.self)
        preprocessKernel = try renderLibrary.function(named: "pointSplatPreprocess", type: ComputeKernel.self)
        splatKernel = try renderLibrary.function(named: "pointSplatSplat", type: ComputeKernel.self)
        resolveKernel = try renderLibrary.function(named: "pointSplatResolve", type: ComputeKernel.self)
        blendKernel = try shaderLibrary.namespaced("TemporalAccumulationShader").function(named: "blend", type: ComputeKernel.self)
        let blitLibrary = shaderLibrary.namespaced("BlitShader")
        blitVertexShader = try blitLibrary.function(named: "vertex_main", type: VertexShader.self)
        // The accumulation texture holds sRGB-encoded splat values (the paper
        // averages in sRGB); linearize so the sRGB drawable's store encode
        // round-trips instead of double-encoding (#68).
        var blitConstants = FunctionConstants()
        blitConstants["convert_srgb_to_linear"] = .bool(true)
        blitFragmentShader = try blitLibrary.function(named: "fragment_main", type: FragmentShader.self, constants: blitConstants)

        resources = try PointSplatResources(drawableSize: drawableSize, splatCount: splatCloud.count, maxPointsPerFrame: maxPointsPerFrame, supersampling: max(supersampling, 1))
    }

    /// `@MSState` persists resources across body evaluations, so a splat
    /// cloud swap (e.g. switching models in the demo) can outgrow the counts
    /// buffer and distributor before `.onChange` fires. Validate eagerly.
    private func validatedResources() throws -> PointSplatResources {
        let width = max(Int(drawableSize.x), 1)
        let height = max(Int(drawableSize.y), 1)
        if resources.splatCount != splatCloud.count || resources.width != width || resources.height != height {
            resources = try PointSplatResources(drawableSize: drawableSize, splatCount: splatCloud.count, maxPointsPerFrame: resources.distributor.capacity, supersampling: supersampling)
        }
        return resources
    }

    public var body: some Element {
        get throws {
            let resources = try validatedResources()
            let width = resources.width
            let height = resources.height
            let bufferWidth = width * supersampling
            let bufferHeight = height * supersampling
            let pixelCount = bufferWidth * bufferHeight
            let uniforms = PointSplatUniforms(
                modelMatrix: modelMatrix,
                viewMatrix: cameraMatrix.inverse,
                projectionMatrix: projectionMatrix,
                drawableSize: SIMD2<Float>(Float(bufferWidth), Float(bufferHeight)),
                nearPlane: 0.2,
                farPlane: 200.0,
                splatCount: UInt32(splatCloud.count),
                frameSeed: frameIndex,
                capacity: UInt32(resources.distributor.capacity),
                supersampling: UInt32(supersampling),
                pointsPerThread: UInt32(pointsPerThread),
                cameraPosition: SIMD3<Float>(cameraMatrix.columns.3.x, cameraMatrix.columns.3.y, cameraMatrix.columns.3.z),
                shDegree: UInt32(splatCloud.shCoefficients != nil ? splatCloud.shDegree : 0)
            )
            let shBuffer = splatCloud.shCoefficients?.unsafeMTLBuffer ?? resources.dummySHBuffer
            // Running mean: weight the new frame by 1/(n+1); camera or model
            // motion resets n so stale accumulation never ghosts.
            let accumulation = resources.nextAccumulationStep(cameraMatrix: cameraMatrix, modelMatrix: modelMatrix, projectionMatrix: projectionMatrix)
            let blockThreads = MTLSize(width: 256, height: 1, depth: 1)
            let clearValue = resources.clearValue

            try ComputePass(label: "PointSplat") {
                try ComputePipeline(computeKernel: clearKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: pixelCount, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                        .parameter("framebuffer", buffer: resources.framebuffer)
                        .parameter("clearValue", value: clearValue)
                        .parameter("pixelCount", value: UInt32(pixelCount))
                }
                try ComputePipeline(computeKernel: preprocessKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: splatCloud.count, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                        .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                        .parameter("counts", buffer: resources.counts)
                        .parameter("uniforms", value: uniforms)
                        .parameter("shCoefficients", buffer: shBuffer)
                        .parameter("colors", buffer: resources.colors)
                }
                try ComputePipeline(computeKernel: splatKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: resources.distributor.capacity, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                        .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                        .parameter("indices", buffer: resources.distributor.indicesBuffer)
                        .parameter("framebuffer", buffer: resources.framebuffer)
                        .parameter("uniforms", value: uniforms)
                        .parameter("totals", buffer: resources.distributor.totalsBuffer)
                        .parameter("framebufferRead", buffer: resources.framebuffer)
                        .parameter("colors", buffer: resources.colors)
                }
                // Encode the workload distribution (prefix sum, scatter,
                // max-scan) into the encoder just before the splat dispatch.
                .onWorkloadEnter { [splatCloud] environmentValues in
                    guard let encoder = environmentValues.computeCommandEncoder else {
                        preconditionFailure("No compute command encoder found.")
                    }
                    try resources.distributor.encode(encoder: encoder, counts: resources.counts, count: splatCloud.count)
                }
                try ComputePipeline(computeKernel: resolveKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        .parameter("framebuffer", buffer: resources.framebuffer)
                        .parameter("uniforms", value: uniforms)
                        .parameter("outTexture", texture: resources.resolveTexture)
                }
                try ComputePipeline(computeKernel: blendKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                        .parameter("currentFrame", texture: resources.resolveTexture)
                        .parameter("accumulationTexture", texture: accumulation.input)
                        .parameter("outputTexture", texture: accumulation.output)
                        .parameter("blendFactor", value: accumulation.blendFactor)
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

/// Per-drawable-size GPU resources for ``PointSplatRenderPipeline``.
final class PointSplatResources {
    let width: Int
    let height: Int
    let framebuffer: MTLBuffer
    let counts: MTLBuffer
    let colors: MTLBuffer
    let dummySHBuffer: MTLBuffer
    let splatCount: Int
    let distributor: PointSplatWorkloadDistributor
    let resolveTexture: MTLTexture
    private let accumulationTextures: [MTLTexture]
    private(set) var accumulatedFrames: Int = 0
    private var frameParity: Int = 0
    private var lastCameraMatrix: simd_float4x4?
    private var lastModelMatrix: simd_float4x4?
    private var lastProjectionMatrix: simd_float4x4?

    var clearValue: UInt64 {
        UInt64(GPS_DEPTH_MAX) << UInt64(GPS_DEPTH_SHIFT)
    }

    init(drawableSize: SIMD2<Float>, splatCount: Int, maxPointsPerFrame: Int, supersampling: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PointSplatRenderer.RendererError.unsupportedDevice
        }
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            throw PointSplatRenderer.RendererError.unsupportedDevice
        }
        width = max(Int(drawableSize.x), 1)
        height = max(Int(drawableSize.y), 1)
        let pixelCount = width * height * supersampling * supersampling

        guard let framebuffer = device.makeBuffer(length: MemoryLayout<UInt64>.stride * pixelCount, options: .storageModePrivate), let counts = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(splatCount, 1), options: .storageModePrivate), let colors = device.makeBuffer(length: MemoryLayout<UInt64>.stride * max(splatCount, 1), options: .storageModePrivate), let dummySHBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModePrivate) else {
            throw PointSplatRenderer.RendererError.bufferAllocationFailed
        }
        framebuffer.label = "PointSplat framebuffer64"
        colors.label = "PointSplat colors"
        self.framebuffer = framebuffer
        self.counts = counts
        self.colors = colors
        self.dummySHBuffer = dummySHBuffer
        self.splatCount = splatCount
        distributor = try PointSplatWorkloadDistributor(device: device, capacity: maxPointsPerFrame, maxSplats: splatCount)

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

    struct AccumulationStep {
        var input: MTLTexture
        var output: MTLTexture
        var blendFactor: Float
    }

    /// Resets the running mean when the view changes, then advances the
    /// ping-pong textures and returns this frame's blend inputs.
    func nextAccumulationStep(cameraMatrix: simd_float4x4, modelMatrix: simd_float4x4, projectionMatrix: simd_float4x4) -> AccumulationStep {
        if lastCameraMatrix != cameraMatrix || lastModelMatrix != modelMatrix || lastProjectionMatrix != projectionMatrix {
            accumulatedFrames = 0
        }
        lastCameraMatrix = cameraMatrix
        lastModelMatrix = modelMatrix
        lastProjectionMatrix = projectionMatrix

        let step = AccumulationStep(
            input: accumulationTextures[frameParity],
            output: accumulationTextures[(frameParity + 1) % 2],
            blendFactor: 1.0 / Float(accumulatedFrames + 1)
        )
        accumulatedFrames += 1
        frameParity = (frameParity + 1) % 2
        return step
    }
}

#endif
