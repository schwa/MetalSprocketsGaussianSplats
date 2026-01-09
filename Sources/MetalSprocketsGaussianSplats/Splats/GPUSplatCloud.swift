#if !arch(x86_64)
internal import AsyncAlgorithms
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplatShaders
internal import os
import simd
import Splats

// @unchecked Sendable required because indexedDistances is mutated from async sort tasks.
// The mutation is coordinated through AsyncSortManager's actor isolation.
public final class GPUSplatCloud <Splat>: Equatable, @unchecked Sendable where Splat: SortableSplatProtocol {
    public private(set) var splats: TypedMTLBuffer<Splat>
    internal var indexedDistances: SplatIndices

    /// Per-cloud model transform
    public var modelTransform: simd_float4x4

    /// Spherical harmonics coefficients buffer (optional, for view-dependent color)
    public var shCoefficients: TypedMTLBuffer<Float>?

    /// Spherical harmonics degree (0 = no SH, 1-3 for increasing detail)
    public var shDegree: UInt8

    // MARK: -

    public init(splats: TypedMTLBuffer<Splat>, indexedDistances: SplatIndices, modelTransform: simd_float4x4 = .identity, shCoefficients: TypedMTLBuffer<Float>? = nil, shDegree: UInt8 = 0) {
        self.splats = splats
        self.indexedDistances = indexedDistances
        self.modelTransform = modelTransform
        self.shCoefficients = shCoefficients
        self.shDegree = shDegree
    }

    public convenience init(device: MTLDevice, splats: TypedMTLBuffer<Splat>, cameraMatrix: simd_float4x4, modelMatrix: simd_float4x4) throws {
        let indexedDistances = try CPUSplatRadixSorter.sort(device: device, splats: splats, camera: cameraMatrix, model: modelMatrix, reversed: false)
        self.init(splats: splats, indexedDistances: indexedDistances, modelTransform: modelMatrix)
    }

    public convenience init(device: MTLDevice, splats: [Splat], cameraMatrix: simd_float4x4, modelMatrix: simd_float4x4) throws {
        let splats = try device.makeTypedBuffer(values: splats, options: [])
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    // MARK: -

    public static func == (lhs: GPUSplatCloud, rhs: GPUSplatCloud) -> Bool {
        lhs.splats == rhs.splats && lhs.indexedDistances == rhs.indexedDistances && lhs.modelTransform == rhs.modelTransform && lhs.shCoefficients == rhs.shCoefficients && lhs.shDegree == rhs.shDegree
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
