#if !arch(x86_64)

import GeometryLite3D
@preconcurrency import Metal
import MetalSprocketsGaussianSplatShaders
internal import os
import simd
import Splats
import Synchronization

/// A splat cloud whose splat data lives in Metal buffers, ready for GPU rendering.
///
/// Holds the splat buffer, an optional spherical-harmonics coefficient buffer,
/// a per-cloud model transform, and a cloud-level opacity. Equality is by
/// reference, because a comparison of the buffer contents is too expensive for
/// large clouds.
public final class GPUSplatCloud <Splat>: Equatable, Sendable where Splat: SortableSplatProtocol {
    public let splats: TypedMTLBuffer<Splat>

    /// Mutable state shared between the UI (writes) and the sort thread (reads).
    /// A mutex guards it, so a 64-byte matrix cannot tear mid-sort (#93).
    private struct MutableState {
        var modelTransform: simd_float4x4
        var opacity: Float
    }

    private let state: Mutex<MutableState>

    /// The per-cloud model transform.
    public var modelTransform: simd_float4x4 {
        get { state.withLock { $0.modelTransform } }
        set { state.withLock { $0.modelTransform = newValue } }
    }

    /// The spherical harmonics coefficient buffer. Optional, for view-dependent color.
    public let shCoefficients: TypedMTLBuffer<Float>?

    /// The spherical harmonics degree. 0 means no SH; 1 to 3 give more detail.
    public let shDegree: UInt8

    /// The cloud-level opacity multiplier, from 0.0 to 1.0.
    public var opacity: Float {
        get { state.withLock { $0.opacity } }
        set { state.withLock { $0.opacity = newValue } }
    }

    // MARK: -

    public init(splats: TypedMTLBuffer<Splat>, modelTransform: simd_float4x4 = .identity, shCoefficients: TypedMTLBuffer<Float>? = nil, shDegree: UInt8 = 0, opacity: Float = 1.0) {
        self.splats = splats
        self.state = Mutex(MutableState(modelTransform: modelTransform, opacity: opacity))
        self.shCoefficients = shCoefficients
        self.shDegree = shDegree
    }

    /// - Parameter mortonOrdered: If true, reorders the splats along a Morton
    ///   curve before upload, so consecutive splats are spatially coherent. This
    ///   tightens the group-culling AABBs (#89).
    public convenience init(device: MTLDevice, splats: [Splat], modelTransform: simd_float4x4 = .identity, opacity: Float = 1.0, mortonOrdered: Bool = false) throws {
        var splats = splats
        if mortonOrdered {
            SplatMortonReorder.reorder(splats: &splats)
        }
        let splatsBuffer = try device.makeTypedBuffer(values: splats, options: []).labeled("Splats")
        self.init(splats: splatsBuffer, modelTransform: modelTransform, opacity: opacity)
    }

    /// - Parameter mortonOrdered: If true, reorders the splats and their SH
    ///   coefficients together along a Morton curve before upload, so
    ///   consecutive splats are spatially coherent. This tightens the
    ///   group-culling AABBs (#89).
    public convenience init(device: MTLDevice, splats: [Splat], modelTransform: simd_float4x4 = .identity, shCoefficients: [Float], shDegree: UInt8, opacity: Float = 1.0, mortonOrdered: Bool = false) throws {
        var splats = splats
        var shCoefficients = shCoefficients
        if mortonOrdered {
            SplatMortonReorder.reorder(splats: &splats, shCoefficients: &shCoefficients)
        }
        let splatsBuffer = try device.makeTypedBuffer(values: splats, options: []).labeled("Splats")
        let shBuffer = try device.makeTypedBuffer(values: shCoefficients, options: []).labeled("SHCoefficients")
        self.init(splats: splatsBuffer, modelTransform: modelTransform, shCoefficients: shBuffer, shDegree: shDegree, opacity: opacity)
    }

    // MARK: -

    public static func == (lhs: GPUSplatCloud, rhs: GPUSplatCloud) -> Bool {
        // Reference equality. A comparison of the buffer contents is too expensive for large splat clouds.
        lhs === rhs
    }

    /// The number of splats in the splat cloud.
    public var count: Int {
        splats.count
    }
}

// MARK: -

/// Sorted splat indices produced by a CPU or GPU sort, ready for indexed drawing.
public struct SplatIndices: Sendable, Equatable {
    var parameters: SortParameters
    var indices: TypedMTLBuffer<IndexedDistance>
    /// The pool this buffer came from. Stored so release does not depend on
    /// which pool the sort manager currently holds. Pools are swapped on resize.
    private var pool: Pool<TypedMTLBuffer<IndexedDistance>>?
    /// Indirect draw arguments (`MTLDrawPrimitivesIndirectArguments`). The
    /// `instanceCount` is the number of splats that pass the GPU cull. Nil for
    /// CPU-sorted indices, where every index is drawn.
    public internal(set) var indirectDrawArgs: MTLBuffer?

    internal init(parameters: SortParameters, indices: TypedMTLBuffer<IndexedDistance>, pool: Pool<TypedMTLBuffer<IndexedDistance>>? = nil, indirectDrawArgs: MTLBuffer? = nil) {
        self.parameters = parameters
        self.indices = indices
        self.pool = pool
        self.indirectDrawArgs = indirectDrawArgs
    }

    /// Releases the index buffer back to the pool it came from.
    public func release() {
        pool?.release(indices)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.parameters == rhs.parameters && lhs.indices == rhs.indices
    }
}

// MARK: -

/// The camera and model state that a sort was, or must be, computed for.
///
/// Renderers compare the parameters of the most recent sort against the current
/// frame to decide whether a re-sort is needed.
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
