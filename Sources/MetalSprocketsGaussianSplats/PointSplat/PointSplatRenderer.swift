#if !arch(x86_64)

import Metal
import MetalSprockets
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
/// A thin blocking wrapper around ``PointSplatComputePass``: this class only
/// adds a private command queue and a CPU-readable output texture. For
/// element-tree composition use ``PointSplatComputePass`` directly; for live
/// rendering with temporal accumulation use ``PointSplatRenderPipeline``.
///
/// Requires 64-bit atomics: Apple9 (A17/M3+) or Mac2 GPU family.
public final class PointSplatRenderer {
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
            self.supersampling = max(supersampling, 1)
            self.pointsPerThread = max(pointsPerThread, 1)
        }

        /// Frame point budget (T), derived from the supersampled size.
        var pointBudget: Int {
            PointSplatWorkloadDistributor.capacity(forSupersampledPixels: width * height * supersampling * supersampling, pointsPerThread: pointsPerThread)
        }
    }

    public let device: MTLDevice
    public let configuration: Configuration

    /// Called after each blocking render with the GPU timestamp sample for the
    /// frame's compute pass (whole-encoder time; there are no render stages).
    /// Set before calling `render`. `nil` (the default) skips counter sampling.
    public var onGPUCounterSample: (@Sendable (GPUCounterSample) -> Void)?

    private let runner: Runner
    private let outTexture: MTLTexture
    /// Monotonic per-render key for `framePlan` idempotency; frame seeds can repeat.
    private var planCounter: UInt64 = 0

    public init(device: MTLDevice, configuration: Configuration) throws {
        guard device.supportsFamily(.apple9) || device.supportsFamily(.mac2) else {
            throw PointSplatError.unsupportedDevice
        }
        self.device = device
        self.configuration = configuration

        self.runner = try Runner(device: device)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: configuration.width, height: configuration.height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let outTexture = device.makeTexture(descriptor: descriptor) else {
            throw PointSplatError.textureAllocationFailed
        }
        outTexture.label = "PointSplat resolve"
        self.outTexture = outTexture
    }

    /// Renders one stochastic frame. Blocks until complete.
    public func render(splats: MTLBuffer, splatCount: Int, modelMatrix: simd_float4x4, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, frameSeed: UInt32) throws -> MTLTexture {
        try render(splats: splats, splatCount: splatCount, packedBounds: nil, modelMatrix: modelMatrix, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, frameSeed: frameSeed)
    }

    /// Renders one stochastic frame from quantized 18-byte splats
    /// (issue #77). Blocks until complete.
    public func render(packed cloud: PackedSplatCloud, modelMatrix: simd_float4x4, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, frameSeed: UInt32) throws -> MTLTexture {
        try render(splats: cloud.buffer, splatCount: cloud.count, packedBounds: cloud.bounds, modelMatrix: modelMatrix, viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, frameSeed: frameSeed)
    }

    private func render(splats: MTLBuffer, splatCount: Int, packedBounds: GPSPackedSplatBounds?, modelMatrix: simd_float4x4, viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4, frameSeed: UInt32) throws -> MTLTexture {
        // Explicit plan key: frame seeds can repeat, the counter cannot.
        planCounter += 1
        let pass = PointSplatComputePass(
            splats: splats,
            splatCount: splatCount,
            packedBounds: packedBounds,
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            frameSeed: frameSeed,
            planKey: planCounter,
            outTexture: outTexture,
            nearPlane: configuration.nearPlane,
            farPlane: configuration.farPlane,
            backgroundColor: configuration.backgroundColor,
            supersampling: configuration.supersampling,
            pointsPerThread: configuration.pointsPerThread
        )
        if let onGPUCounterSample {
            try runner.run(pass.gpuCounters(label: "PointSplat offscreen", onGPUCounterSample))
        } else {
            try runner.run(pass)
        }

        return outTexture
    }
}

#endif
