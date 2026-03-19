#if !arch(x86_64)
internal import AsyncAlgorithms
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplatShaders
internal import os
import simd
import Splats

public final class GPUSplatCloud <Splat>: Equatable, @unchecked Sendable where Splat: SortableSplatProtocol {
    public let splats: TypedMTLBuffer<Splat>

    /// Per-cloud model transform
    public var modelTransform: simd_float4x4

    /// Spherical harmonics coefficients buffer (optional, for view-dependent color)
    public let shCoefficients: TypedMTLBuffer<Float>?

    /// Spherical harmonics degree (0 = no SH, 1-3 for increasing detail)
    public let shDegree: UInt8

    /// Cloud-level opacity multiplier (0.0 - 1.0)
    public var opacity: Float

    // MARK: -

    public init(splats: TypedMTLBuffer<Splat>, modelTransform: simd_float4x4 = .identity, shCoefficients: TypedMTLBuffer<Float>? = nil, shDegree: UInt8 = 0, opacity: Float = 1.0) {
        self.splats = splats
        self.modelTransform = modelTransform
        self.shCoefficients = shCoefficients
        self.shDegree = shDegree
        self.opacity = opacity
    }

    public convenience init(device: MTLDevice, splats: [Splat], modelTransform: simd_float4x4 = .identity, opacity: Float = 1.0) throws {
        let splats = try device.makeTypedBuffer(values: splats, options: []).labeled("Splats")
        self.init(splats: splats, modelTransform: modelTransform, opacity: opacity)
    }

    public convenience init(device: MTLDevice, splats: [Splat], modelTransform: simd_float4x4 = .identity, shCoefficients: [Float], shDegree: UInt8, opacity: Float = 1.0) throws {
        let splatsBuffer = try device.makeTypedBuffer(values: splats, options: []).labeled("Splats")
        let shBuffer = try device.makeTypedBuffer(values: shCoefficients, options: []).labeled("SHCoefficients")
        self.init(splats: splatsBuffer, modelTransform: modelTransform, shCoefficients: shBuffer, shDegree: shDegree, opacity: opacity)
    }

    // MARK: -

    public static func == (lhs: GPUSplatCloud, rhs: GPUSplatCloud) -> Bool {
        // Use reference equality - comparing buffer contents is too expensive for large splat clouds
        lhs === rhs
    }

    /// How many splats are currently in the splat cloud
    public var count: Int {
        splats.count
    }
}

// MARK: -

public struct SplatIndices: Sendable, Equatable {
    var parameters: SortParameters
    var indices: TypedMTLBuffer<IndexedDistance>

    public init(parameters: SortParameters, indices: TypedMTLBuffer<IndexedDistance>) {
        self.parameters = parameters
        self.indices = indices
    }
}

// MARK: -

public struct SortParameters: Sendable, Equatable {
    var time: TimeInterval
    var camera: simd_float4x4
    var model: simd_float4x4
    var reversed: Bool

    public init(time: TimeInterval = Date.timeIntervalSinceReferenceDate, camera: simd_float4x4, model: simd_float4x4, reversed: Bool = false) {
        self.time = time
        self.camera = camera
        self.model = model
        self.reversed = reversed
    }
}
#endif
