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
        public var backgroundColor: SIMD3<Float>
        /// Linear supersampling factor S; the framebuffer is S x S larger
        /// and resolved with a box filter. Paper default is 2.
        public var supersampling: Int
        /// Points splatted per thread (K). Paper pairs K = S^2.
        public var pointsPerThread: Int

        public init(width: Int, height: Int, nearPlane: Float = 0.2, farPlane: Float = 100.0, backgroundColor: SIMD3<Float> = .zero, supersampling: Int = 1, pointsPerThread: Int = 1) {
            self.width = width
            self.height = height
            self.nearPlane = nearPlane
            self.farPlane = farPlane
            self.backgroundColor = backgroundColor
            self.supersampling = supersampling
            self.pointsPerThread = pointsPerThread
        }

        /// Frame point budget (T), derived from the supersampled size.
        var pointBudget: Int {
            PointSplatWorkloadDistributor.capacity(forSupersampledPixels: width * height * supersampling * supersampling)
        }
    }

    public let device: MTLDevice
    public let configuration: Configuration

    private let commandQueue: MTLCommandQueue
    private let clear: MTLComputePipelineState
    private let preprocess: MTLComputePipelineState
    private let splat: MTLComputePipelineState
    private let resolve: MTLComputePipelineState
    private var distributor: PointSplatWorkloadDistributor?
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

        let pixelCount = configuration.width * configuration.height * configuration.supersampling * configuration.supersampling
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
        let supersampling = max(configuration.supersampling, 1)
        var uniforms = PointSplatUniforms(
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            drawableSize: SIMD2<Float>(Float(configuration.width * supersampling), Float(configuration.height * supersampling)),
            nearPlane: configuration.nearPlane,
            farPlane: configuration.farPlane,
            splatCount: UInt32(splatCount),
            frameSeed: frameSeed,
            capacity: UInt32(configuration.pointBudget),
            supersampling: UInt32(supersampling),
            pointsPerThread: UInt32(max(configuration.pointsPerThread, 1)),
            cameraPosition: .zero,
            shDegree: 0
        )
        let pixelCount = configuration.width * configuration.height * supersampling * supersampling
        var pixelCountValue = UInt32(pixelCount)
        // Far depth + background color: any splatted point wins the min.
        let background = configuration.backgroundColor
        var clearValue = (UInt64(GPS_DEPTH_MAX) << UInt64(GPS_DEPTH_SHIFT)) | gps_pack_color(background.x, background.y, background.z)

        guard let counts = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(splatCount, 1), options: .storageModePrivate), let colors = device.makeBuffer(length: MemoryLayout<UInt64>.stride * max(splatCount, 1), options: .storageModePrivate), let dummySH = device.makeBuffer(length: MemoryLayout<Float>.stride, options: .storageModePrivate) else {
            throw RendererError.bufferAllocationFailed
        }
        if distributor == nil || distributor?.maxSplats ?? 0 < splatCount {
            distributor = try PointSplatWorkloadDistributor(device: device, capacity: configuration.pointBudget, maxSplats: splatCount)
        }
        guard let distributor else {
            throw RendererError.bufferAllocationFailed
        }

        // Whole frame in one serial compute encoder; the splat dispatch is
        // sized to capacity and exits threads past the GPU-side total.
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RendererError.commandEncodingFailed
        }
        encoder.setComputePipelineState(clear)
        encoder.setBuffer(framebuffer, offset: 0, index: 0)
        encoder.setBytes(&clearValue, length: MemoryLayout<UInt64>.stride, index: 1)
        encoder.setBytes(&pixelCountValue, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: pixelCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoder.setComputePipelineState(preprocess)
        encoder.setBuffer(splats, offset: 0, index: 0)
        encoder.setBuffer(counts, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<PointSplatUniforms>.stride, index: 2)
        encoder.setBuffer(dummySH, offset: 0, index: 3)
        encoder.setBuffer(colors, offset: 0, index: 4)
        encoder.dispatchThreads(MTLSize(width: splatCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        try distributor.encode(encoder: encoder, counts: counts, count: splatCount)

        encoder.setComputePipelineState(splat)
        encoder.setBuffer(splats, offset: 0, index: 0)
        encoder.setBuffer(distributor.indicesBuffer, offset: 0, index: 1)
        encoder.setBuffer(framebuffer, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<PointSplatUniforms>.stride, index: 3)
        encoder.setBuffer(distributor.totalsBuffer, offset: 0, index: 4)
        encoder.setBuffer(framebuffer, offset: 0, index: 5)
        encoder.setBuffer(colors, offset: 0, index: 6)
        encoder.dispatchThreads(MTLSize(width: configuration.pointBudget, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoder.setComputePipelineState(resolve)
        encoder.setBuffer(framebuffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<PointSplatUniforms>.stride, index: 1)
        encoder.setTexture(outTexture, index: 0)
        encoder.dispatchThreads(MTLSize(width: configuration.width, height: configuration.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return outTexture
    }
}

#endif
