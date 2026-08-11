#if !arch(x86_64)

import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import Splats

/// One offscreen PointSplat frame (RFC 0003) as a composable element:
/// clear, stochastic point splatting, and a box-filter resolve into
/// `outTexture`.
///
/// This is the element-based counterpart to ``PointSplatRenderer``: place it
/// in an element tree (a `Runner`, alongside other passes in one submission)
/// and attach modifiers such as `gpuCounters`. Output at 1 sample per pixel
/// is noisy by design — accumulate frames (varying `frameSeed`) for a
/// converged image. For live rendering with temporal accumulation use
/// ``PointSplatRenderPipeline``.
///
/// Requires 64-bit atomics: Apple9 (A17/M3+) or Mac2 GPU family.
public struct PointSplatComputePass: Element {
    private var splats: MTLBuffer
    private var splatCount: Int
    private var packedBounds: GPSPackedSplatBounds?
    private var modelMatrix: simd_float4x4
    private var viewMatrix: simd_float4x4
    private var projectionMatrix: simd_float4x4
    private var frameSeed: UInt32
    private var planKey: UInt64
    private var outTexture: MTLTexture
    private var nearPlane: Float
    private var farPlane: Float
    private var backgroundColor: SIMD3<Float>
    private var supersampling: Int
    private var pointsPerThread: Int

    @MSState private var resources: PointSplatResources?

    @MSEnvironment(\.device)
    private var environmentDevice

    /// Renders one stochastic frame of `splatCloud` into `outTexture`.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        modelMatrix: simd_float4x4,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        frameSeed: UInt32,
        planKey: UInt64? = nil,
        outTexture: MTLTexture,
        nearPlane: Float = 0.2,
        farPlane: Float = 100.0,
        backgroundColor: SIMD3<Float> = .zero,
        supersampling: Int = 1,
        pointsPerThread: Int = 1
    ) {
        self.init(
            splats: splatCloud.splats.unsafeMTLBuffer,
            splatCount: splatCloud.count,
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            frameSeed: frameSeed,
            planKey: planKey,
            outTexture: outTexture,
            nearPlane: nearPlane,
            farPlane: farPlane,
            backgroundColor: backgroundColor,
            supersampling: supersampling,
            pointsPerThread: pointsPerThread
        )
    }

    /// Renders one stochastic frame from a raw splat buffer, or — when
    /// `packedBounds` is set — from quantized 18-byte packed splats.
    ///
    /// - Parameters:
    ///   - splats: `SparkSplat` (or packed) splat data.
    ///   - splatCount: Number of splats in `splats`.
    ///   - packedBounds: Dequantization bounds; set when `splats` holds
    ///     18-byte packed splats.
    ///   - modelMatrix: The scene-level model transform.
    ///   - viewMatrix: The world-to-view matrix.
    ///   - projectionMatrix: The camera projection matrix.
    ///   - frameSeed: Varies the stochastic sampling pattern.
    ///   - planKey: Monotonic per-frame key for frame-plan idempotency.
    ///     Defaults to `frameSeed`; pass an explicit key when seeds can
    ///     repeat across frames.
    ///   - outTexture: Destination texture; its size sets the output size.
    ///   - nearPlane: View-space near distance for depth quantization and the near cull.
    ///   - farPlane: View-space far distance for depth quantization.
    ///   - backgroundColor: Color of pixels no point lands on.
    ///   - supersampling: Linear supersampling factor S.
    ///   - pointsPerThread: Points splatted per thread (K).
    public init(
        splats: MTLBuffer,
        splatCount: Int,
        packedBounds: GPSPackedSplatBounds? = nil,
        modelMatrix: simd_float4x4,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        frameSeed: UInt32,
        planKey: UInt64? = nil,
        outTexture: MTLTexture,
        nearPlane: Float = 0.2,
        farPlane: Float = 100.0,
        backgroundColor: SIMD3<Float> = .zero,
        supersampling: Int = 1,
        pointsPerThread: Int = 1
    ) {
        self.splats = splats
        self.splatCount = splatCount
        self.packedBounds = packedBounds
        self.modelMatrix = modelMatrix
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.frameSeed = frameSeed
        self.planKey = planKey ?? UInt64(frameSeed)
        self.outTexture = outTexture
        self.nearPlane = nearPlane
        self.farPlane = farPlane
        self.backgroundColor = backgroundColor
        self.supersampling = max(supersampling, 1)
        self.pointsPerThread = max(pointsPerThread, 1)
    }

    /// Resources are created lazily on the device MetalSprockets publishes via
    /// the environment, and rebuilt when any sizing input changes.
    /// `@MSState` persists them across body evaluations and frames.
    private func validatedResources() throws -> PointSplatResources {
        guard let device = environmentDevice else {
            throw MetalSprocketsError.missingEnvironment(\.device)
        }
        if let resources, resources.device === device, resources.splatCount == splatCount, resources.width == outTexture.width, resources.height == outTexture.height, resources.supersampling == supersampling, resources.pointsPerThread == pointsPerThread, resources.backgroundColor == backgroundColor {
            return resources
        }
        let newResources = try PointSplatResources(
            device: device,
            drawableSize: SIMD2<Float>(Float(outTexture.width), Float(outTexture.height)),
            splatCount: splatCount,
            supersampling: supersampling,
            pointsPerThread: pointsPerThread,
            backgroundColor: backgroundColor
        )
        resources = newResources
        return newResources
    }

    public var body: some Element {
        get throws {
            let resources = try validatedResources()
            let uniforms = PointSplatUniforms(
                modelMatrix: modelMatrix,
                viewMatrix: viewMatrix,
                projectionMatrix: projectionMatrix,
                drawableSize: SIMD2<Float>(Float(outTexture.width * supersampling), Float(outTexture.height * supersampling)),
                nearPlane: nearPlane,
                farPlane: farPlane,
                splatCount: UInt32(splatCount),
                frameSeed: frameSeed,
                capacity: UInt32(resources.distributor.capacity),
                supersampling: UInt32(supersampling),
                pointsPerThread: UInt32(pointsPerThread),
                cameraPosition: .zero,
                shDegree: 0,
                occlusionPhase: 0,
                pyramidLevels: UInt32(resources.pyramidLevels),
                packedSplats: packedBounds == nil ? 0 : 1,
                // Offline path stays at rho = 0: principled convergence for
                // ground-truth accumulation (RFC 0005 §4).
                reuseFactor: 0
            )
            // Whole frame in one serial compute pass; the splat dispatches
            // are indirect from the GPU-side totals.
            let plan = resources.framePlan(planKey: planKey, splats: splats)
            return try ComputePass(label: "PointSplat offscreen") {
                try resources.frameElements(uniforms: uniforms, splats: splats, shBuffer: resources.dummySHBuffer, seed: frameSeed, packedBounds: packedBounds ?? GPSPackedSplatBounds(), plan: plan)
                try resources.resolveElements(uniforms: uniforms, outTexture: outTexture)
            }
        }
    }
}

#endif
