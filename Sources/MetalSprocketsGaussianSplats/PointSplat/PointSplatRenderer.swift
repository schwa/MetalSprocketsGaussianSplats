#if !arch(x86_64)

import Metal
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

/// Sort-free stochastic point renderer (RFC 0003).
///
/// One-shot offscreen renderer: samples pixel-sized opaque points from
/// Gaussians and splats them into a 64-bit depth+color buffer with
/// `atomic_min`; no sort, no tile binning, no blending. Output at 1 sample
/// per pixel is noisy by design — accumulate frames (varying `frameSeed`)
/// for a converged image.
///
/// Requires 64-bit atomics: Apple9 (A17/M3+) or Mac2 GPU family.
public final class PointSplatRenderer {
    public enum RendererError: Error {
        case unsupportedDevice
        case bufferAllocationFailed
        case commandEncodingFailed
        case functionNotFound(String)
        case textureAllocationFailed
    }

    public struct Configuration {
        public var width: Int
        public var height: Int
        /// View-space near distance for depth quantization and the near cull.
        public var nearPlane: Float
        /// View-space far distance for depth quantization.
        public var farPlane: Float
        /// Point budget per frame (T in the paper).
        public var maxPointsPerFrame: Int
        public var backgroundColor: SIMD3<Float>

        public init(width: Int, height: Int, nearPlane: Float = 0.2, farPlane: Float = 100.0, maxPointsPerFrame: Int = 4_000_000, backgroundColor: SIMD3<Float> = .zero) {
            self.width = width
            self.height = height
            self.nearPlane = nearPlane
            self.farPlane = farPlane
            self.maxPointsPerFrame = maxPointsPerFrame
            self.backgroundColor = backgroundColor
        }
    }

    public let device: MTLDevice
    public let configuration: Configuration

    private let commandQueue: MTLCommandQueue
    private let clear: MTLComputePipelineState
    private let preprocess: MTLComputePipelineState
    private let splat: MTLComputePipelineState
    private let resolve: MTLComputePipelineState
    private let distributor: PointSplatWorkloadDistributor
    private let framebuffer: MTLBuffer
    private let outTexture: MTLTexture

    public init(device: MTLDevice, configuration: Configuration) throws {
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            throw RendererError.unsupportedDevice
        }
        self.device = device
        self.configuration = configuration

        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandEncodingFailed
        }
        self.commandQueue = commandQueue

        let library = try device.makeDefaultLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: "PointSplatRender::\(name)") else {
                throw RendererError.functionNotFound(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        clear = try pipeline("pointSplatClear")
        preprocess = try pipeline("pointSplatPreprocess")
        splat = try pipeline("pointSplatSplat")
        resolve = try pipeline("pointSplatResolve")

        distributor = try PointSplatWorkloadDistributor(device: device, capacity: configuration.maxPointsPerFrame)

        let pixelCount = configuration.width * configuration.height
        guard let framebuffer = device.makeBuffer(length: MemoryLayout<UInt64>.stride * pixelCount, options: .storageModePrivate) else {
            throw RendererError.bufferAllocationFailed
        }
        framebuffer.label = "PointSplat framebuffer64"
        self.framebuffer = framebuffer

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: configuration.width, height: configuration.height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let outTexture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.textureAllocationFailed
        }
        outTexture.label = "PointSplat resolve"
        self.outTexture = outTexture
    }

    /// Renders one stochastic frame. Blocks until complete.
    public func render(splats: MTLBuffer, splatCount: Int, modelMatrix: simd_float4x4, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, frameSeed: UInt32) throws -> MTLTexture {
        var uniforms = PointSplatUniforms(
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            drawableSize: SIMD2<Float>(Float(configuration.width), Float(configuration.height)),
            nearPlane: configuration.nearPlane,
            farPlane: configuration.farPlane,
            splatCount: UInt32(splatCount),
            frameSeed: frameSeed,
            capacity: UInt32(configuration.maxPointsPerFrame)
        )
        let pixelCount = configuration.width * configuration.height
        var pixelCountValue = UInt32(pixelCount)
        // Far depth + background color: any splatted point wins the min.
        let background = configuration.backgroundColor
        var clearValue = (UInt64(GPS_DEPTH_MAX) << UInt64(GPS_DEPTH_SHIFT)) | gps_pack_color(background.x, background.y, background.z)

        guard let counts = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(splatCount, 1), options: .storageModePrivate) else {
            throw RendererError.bufferAllocationFailed
        }

        // Stage 1: clear + preprocess.
        guard let commandBufferA = commandQueue.makeCommandBuffer(), let encoderA = commandBufferA.makeComputeCommandEncoder() else {
            throw RendererError.commandEncodingFailed
        }
        encoderA.setComputePipelineState(clear)
        encoderA.setBuffer(framebuffer, offset: 0, index: 0)
        encoderA.setBytes(&clearValue, length: MemoryLayout<UInt64>.stride, index: 1)
        encoderA.setBytes(&pixelCountValue, length: MemoryLayout<UInt32>.stride, index: 2)
        encoderA.dispatchThreads(MTLSize(width: pixelCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoderA.setComputePipelineState(preprocess)
        encoderA.setBuffer(splats, offset: 0, index: 0)
        encoderA.setBuffer(counts, offset: 0, index: 1)
        encoderA.setBytes(&uniforms, length: MemoryLayout<PointSplatUniforms>.stride, index: 2)
        encoderA.dispatchThreads(MTLSize(width: splatCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoderA.endEncoding()
        commandBufferA.commit()
        commandBufferA.waitUntilCompleted()

        // Stage 2: work distribution (blocking, includes its own readback).
        let workload = try distributor.build(counts: counts, count: splatCount, commandQueue: commandQueue)

        // Stage 3: splat + resolve.
        guard let commandBufferB = commandQueue.makeCommandBuffer(), let encoderB = commandBufferB.makeComputeCommandEncoder() else {
            throw RendererError.commandEncodingFailed
        }
        if workload.totalPoints > 0 {
            var numPoints = UInt32(workload.totalPoints)
            encoderB.setComputePipelineState(splat)
            encoderB.setBuffer(splats, offset: 0, index: 0)
            encoderB.setBuffer(workload.indices, offset: 0, index: 1)
            encoderB.setBuffer(framebuffer, offset: 0, index: 2)
            encoderB.setBytes(&uniforms, length: MemoryLayout<PointSplatUniforms>.stride, index: 3)
            encoderB.setBytes(&numPoints, length: MemoryLayout<UInt32>.stride, index: 4)
            encoderB.setBuffer(framebuffer, offset: 0, index: 5)
            encoderB.dispatchThreads(MTLSize(width: workload.totalPoints, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        }
        encoderB.setComputePipelineState(resolve)
        encoderB.setBuffer(framebuffer, offset: 0, index: 0)
        encoderB.setBytes(&uniforms, length: MemoryLayout<PointSplatUniforms>.stride, index: 1)
        encoderB.setTexture(outTexture, index: 0)
        encoderB.dispatchThreads(MTLSize(width: configuration.width, height: configuration.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoderB.endEncoding()
        commandBufferB.commit()
        commandBufferB.waitUntilCompleted()

        return outTexture
    }
}

#endif
