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

    public init(splatCloud: GPUSplatCloud<SparkSplat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>, frameIndex: UInt32, maxPointsPerFrame: Int = 4_000_000) throws {
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
        blitFragmentShader = try blitLibrary.function(named: "fragment_main", type: FragmentShader.self)

        resources = try PointSplatResources(drawableSize: drawableSize, splatCount: splatCloud.count, maxPointsPerFrame: maxPointsPerFrame)
    }

    public var body: some Element {
        get throws {
            let width = resources.width
            let height = resources.height
            let pixelCount = width * height
            let uniforms = PointSplatUniforms(
                modelMatrix: modelMatrix,
                viewMatrix: cameraMatrix.inverse,
                projectionMatrix: projectionMatrix,
                drawableSize: SIMD2<Float>(Float(width), Float(height)),
                nearPlane: 0.2,
                farPlane: 200.0,
                splatCount: UInt32(splatCloud.count),
                frameSeed: frameIndex,
                capacity: UInt32(resources.distributor.capacity)
            )
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
                }
                try ComputePipeline(computeKernel: splatKernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: resources.distributor.capacity, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                        .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                        .parameter("indices", buffer: resources.distributor.indicesBuffer)
                        .parameter("framebuffer", buffer: resources.framebuffer)
                        .parameter("uniforms", value: uniforms)
                        .parameter("totals", buffer: resources.distributor.totalsBuffer)
                        .parameter("framebufferRead", buffer: resources.framebuffer)
                }
                // Encode the workload distribution (prefix sum, scatter,
                // max-scan) into the encoder just before the splat dispatch.
                .onWorkloadEnter { [resources, splatCloud] environmentValues in
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
            .onChange(of: drawableSize) { _, newSize in
                resources = try! PointSplatResources(drawableSize: newSize, splatCount: splatCloud.count, maxPointsPerFrame: resources.distributor.capacity)
            }
            .onChange(of: splatCloud) { _, newCloud in
                resources = try! PointSplatResources(drawableSize: drawableSize, splatCount: newCloud.count, maxPointsPerFrame: resources.distributor.capacity)
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

    init(drawableSize: SIMD2<Float>, splatCount: Int, maxPointsPerFrame: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PointSplatRenderer.RendererError.unsupportedDevice
        }
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            throw PointSplatRenderer.RendererError.unsupportedDevice
        }
        width = max(Int(drawableSize.x), 1)
        height = max(Int(drawableSize.y), 1)
        let pixelCount = width * height

        guard let framebuffer = device.makeBuffer(length: MemoryLayout<UInt64>.stride * pixelCount, options: .storageModePrivate), let counts = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(splatCount, 1), options: .storageModePrivate) else {
            throw PointSplatRenderer.RendererError.bufferAllocationFailed
        }
        framebuffer.label = "PointSplat framebuffer64"
        self.framebuffer = framebuffer
        self.counts = counts
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
