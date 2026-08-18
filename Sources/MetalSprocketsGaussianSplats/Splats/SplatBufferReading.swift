#if !arch(x86_64)
import Foundation
import GeometryLite3D
@preconcurrency import Metal
import MetalSprocketsGaussianSplatShaders
import Splats
import simd

// MARK: - SplatBufferResult

/// A GPU-resident splat decode result: a `SparkSplat` buffer plus flattened
/// spherical-harmonics coefficients. This is the common currency for loading
/// any splat format into GPU memory — `SOGReaderGPU` produces it via its
/// compute kernel, and every CPU `SplatReaderProtocol` reader produces it via
/// ``SplatReaderProtocol/read(device:name:)``.
public struct SplatBufferResult {
    public var splats: TypedMTLBuffer<SparkSplat>
    /// Flattened SH coefficients (`count * shFloatsPerSplat` floats); empty when
    /// `shDegree == 0`.
    public var shCoefficients: TypedMTLBuffer<Float>
    public var shDegree: UInt8
    public var count: Int

    public init(splats: TypedMTLBuffer<SparkSplat>, shCoefficients: TypedMTLBuffer<Float>, shDegree: UInt8, count: Int) {
        self.splats = splats
        self.shCoefficients = shCoefficients
        self.shDegree = shDegree
        self.count = count
    }
}

// MARK: - CPU readers -> buffers

public extension SplatReaderProtocol {
    /// Decode this file into GPU buffers, converting each streamed splat to a
    /// `SparkSplat`. The `SparkSplat` conversion lives in this module (above the
    /// `Splats` decode layer), so this extension does too.
    ///
    /// - Parameters:
    ///   - device: Device to allocate the output buffers on.
    ///   - name: Optional label for the buffers (GPU-capture identification).
    ///   - mortonOrdered: When true, reorders splats (and their SH, in lockstep)
    ///     along a Morton curve before upload for group-culling coherence (#89).
    func read(device: MTLDevice, name: String? = nil, mortonOrdered: Bool = false) throws -> SplatBufferResult {
        let degree = shDegree
        var splats: [SparkSplat] = []
        splats.reserveCapacity(splatCount)
        var sh: [Float] = []
        try read { _, extended in
            splats.append(SparkSplat(extended.genericSplat))
            if degree > 0, let coefficients = extended.sphericalHarmonics {
                for coefficient in coefficients {
                    sh.append(contentsOf: coefficient)
                }
            }
        }

        if mortonOrdered {
            if degree > 0, !splats.isEmpty, sh.count % splats.count == 0 {
                SplatMortonReorder.reorder(splats: &splats, shCoefficients: &sh)
            } else {
                SplatMortonReorder.reorder(splats: &splats)
            }
        }

        let label = name ?? "splats"
        let splatsBuffer = try device.makeTypedBuffer(values: splats, options: [.storageModeShared]).labeled("Splats (\(label))")
        // makeBuffer rejects a zero-length buffer, so allocate a 1-float
        // placeholder when there is no SH and report count 0.
        var shBuffer = try device.makeTypedBuffer(values: sh.isEmpty ? [0] : sh, options: [.storageModeShared]).labeled("SHCoefficients (\(label))")
        shBuffer.count = degree > 0 ? sh.count : 0

        return SplatBufferResult(splats: splatsBuffer, shCoefficients: shBuffer, shDegree: degree, count: splats.count)
    }
}

// MARK: - GPU reader bridges

public extension SOGReaderGPU.Result {
    /// This GPU decode result as the common ``SplatBufferResult``.
    var bufferResult: SplatBufferResult {
        SplatBufferResult(splats: splats, shCoefficients: shCoefficients, shDegree: shDegree, count: count)
    }
}

public extension SPZReaderGPU.Result {
    /// This GPU decode result as the common ``SplatBufferResult``.
    var bufferResult: SplatBufferResult {
        SplatBufferResult(splats: splats, shCoefficients: shCoefficients, shDegree: shDegree, count: count)
    }
}

// MARK: - Unified loader

/// Loads any supported splat file into GPU buffers, routing `.sog` and `.spz`
/// through their compute-shader decoders (`SOGReaderGPU` / `SPZReaderGPU`) and
/// `.ply` through the CPU reader's ``SplatReaderProtocol/read(device:name:)``.
public enum SplatLoader {
    /// - Parameter mortonOrdered: Applies to the CPU decode path (`.ply`) only;
    ///   the GPU decoders write straight into buffers in source order.
    public static func read(device: MTLDevice, url: URL, name: String? = nil, mortonOrdered: Bool = false) throws -> SplatBufferResult {
        switch url.pathExtension.lowercased() {
        case "sog":
            return try SOGReaderGPU(device: device).read(url: url, name: name).bufferResult
        case "spz":
            return try SPZReaderGPU(device: device).read(url: url, name: name).bufferResult
        default:
            return try SplatReader(url: url).read(device: device, name: name, mortonOrdered: mortonOrdered)
        }
    }
}

// MARK: - Cloud construction

public extension GPUSplatCloud where Splat == SparkSplat {
    /// Builds a cloud directly from a decoded ``SplatBufferResult``.
    convenience init(_ result: SplatBufferResult, modelTransform: simd_float4x4 = .identity, opacity: Float = 1.0) {
        self.init(
            splats: result.splats,
            modelTransform: modelTransform,
            shCoefficients: result.shDegree > 0 ? result.shCoefficients : nil,
            shDegree: result.shDegree,
            opacity: opacity
        )
    }
}
#endif
