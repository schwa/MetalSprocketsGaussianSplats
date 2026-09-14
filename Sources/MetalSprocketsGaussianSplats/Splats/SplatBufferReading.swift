#if !arch(x86_64)
import Foundation
import GeometryLite3D
@preconcurrency import Metal
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

// MARK: - SplatBufferResult

/// A GPU-resident splat decode result: a `SparkSplat` buffer and flattened
/// spherical-harmonics coefficients. This is the common form for loading any
/// splat format into GPU memory. `SOGReaderGPU` produces it through its compute
/// kernel, and every CPU `SplatReaderProtocol` reader produces it through
/// ``SplatReaderProtocol/read(device:name:)``.
public struct SplatBufferResult {
    public var splats: TypedMTLBuffer<SparkSplat>
    /// Flattened SH coefficients (`count * shFloatsPerSplat` floats). Empty when
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
    /// Decodes this file into GPU buffers and converts each streamed splat to a
    /// `SparkSplat`. The `SparkSplat` conversion lives in this module, above the
    /// `Splats` decode layer, so this extension does too.
    ///
    /// - Parameters:
    ///   - device: The device to allocate the output buffers on.
    ///   - name: An optional label for the buffers, for GPU-capture identification.
    ///   - mortonOrdered: If true, reorders the splats and their SH together
    ///     along a Morton curve before upload, for group-culling coherence (#89).
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
        for index in splats.indices {
            splats[index].shIndex = UInt32(index)
        }

        if mortonOrdered {
            if degree > 0, !splats.isEmpty, sh.count.isMultiple(of: splats.count) {
                SplatMortonReorder.reorder(splats: &splats, shCoefficients: &sh)
            } else {
                SplatMortonReorder.reorder(splats: &splats)
            }
        }

        let label = name ?? "splats"
        let splatsBuffer = try device.makeTypedBuffer(values: splats, options: [.storageModeShared]).labeled("Splats (\(label))")
        // makeBuffer rejects a zero-length buffer. Allocate a 1-float
        // placeholder when there is no SH, and report count 0.
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

public extension PLYReaderGPU.Result {
    var bufferResult: SplatBufferResult {
        SplatBufferResult(splats: splats, shCoefficients: shCoefficients, shDegree: shDegree, count: count)
    }
}
// MARK: - Unified loader

/// Loads any supported splat file into GPU buffers. It routes `.sog`, `.spz`,
/// and binary little-endian `.ply` files through compute-shader decoders.
public enum SplatLoader {
    /// - Parameter mortonOrdered: Uses CPU decoding for `.ply` when enabled.
    public static func read(device: MTLDevice, url: URL, name: String? = nil, mortonOrdered: Bool = false) throws -> SplatBufferResult {
        switch url.pathExtension.lowercased() {
        case "sog":
            return try SOGReaderGPU(device: device).read(url: url, name: name).bufferResult
        case "spz":
            return try SPZReaderGPU(device: device).read(url: url, name: name).bufferResult
        case "ply":
            let data = try Data(contentsOf: url)
            if !mortonOrdered, try PLYReader(data: data).format == .binaryLittleEndian {
                return try PLYReaderGPU(device: device).read(data: data, name: name ?? url.deletingPathExtension().lastPathComponent).bufferResult
            }
            return try PLYSplatReader(data: data).read(device: device, name: name, mortonOrdered: mortonOrdered)
        case "splat":
            return try Antimatter15Reader(url: url).read(device: device, name: name, mortonOrdered: mortonOrdered)
        default:
            throw SplatLoaderError.unsupportedFormat(url.pathExtension)
        }
    }
}

/// Errors from ``SplatLoader``.
public enum SplatLoaderError: Error, Equatable {
    /// The file extension has no loader.
    case unsupportedFormat(String)
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

    /// Builds a render-ready cloud from application-generated splats, including
    /// optional spherical harmonics.
    ///
    /// This is the entry point for splat data your app produces in memory, with
    /// no file-format round trip. Each ``ExtendedSplat`` carries position, scale,
    /// color, and rotation, plus optional per-splat spherical-harmonics rows. The
    /// initializer converts each splat to a `SparkSplat`, flattens the SH rows
    /// into the coefficient buffer layout the renderers expect, and uploads both.
    ///
    /// - Parameters:
    ///   - device: The device to allocate the buffers on.
    ///   - splats: The application-generated splats.
    ///   - shDegree: The spherical-harmonics degree, 0 for none through 3. When
    ///     greater than 0, every splat must carry `shDegree`'s worth of SH rows.
    ///   - modelTransform: The per-cloud model transform.
    ///   - opacity: The cloud-level opacity multiplier, 0.0 to 1.0.
    ///   - mortonOrdered: If true, reorders the splats and their SH together
    ///     along a Morton curve before upload, for group-culling coherence (#89).
    ///   - name: An optional label for the buffers, for GPU-capture identification.
    /// - Throws: ``GPUSplatCloudError`` when a splat's SH rows do not match
    ///   `shDegree`.
    convenience init(
        device: MTLDevice,
        splats: [ExtendedSplat],
        shDegree: UInt8 = 0,
        modelTransform: simd_float4x4 = .identity,
        opacity: Float = 1.0,
        mortonOrdered: Bool = false,
        name: String? = nil
    ) throws {
        guard shDegree <= 3 else {
            throw GPUSplatCloudError.unsupportedSphericalHarmonicsDegree(shDegree)
        }
        var sparkSplats: [SparkSplat] = []
        sparkSplats.reserveCapacity(splats.count)
        var sh: [Float] = []
        let basisCount = Self.shBasisCount(forDegree: shDegree)
        if shDegree > 0 {
            sh.reserveCapacity(splats.count * basisCount * 3)
        }
        for splat in splats {
            var sparkSplat = SparkSplat(splat.genericSplat)
            sparkSplat.shIndex = UInt32(sparkSplats.count)
            sparkSplats.append(sparkSplat)
            guard shDegree > 0 else {
                continue
            }
            let rows = splat.sphericalHarmonics ?? []
            guard rows.count == basisCount, rows.allSatisfy({ $0.count == 3 }) else {
                throw GPUSplatCloudError.malformedSphericalHarmonics(expectedRows: basisCount, actualRows: rows.count)
            }
            for row in rows {
                sh.append(contentsOf: row)
            }
        }

        if mortonOrdered {
            if shDegree > 0, !sparkSplats.isEmpty, sh.count.isMultiple(of: sparkSplats.count) {
                SplatMortonReorder.reorder(splats: &sparkSplats, shCoefficients: &sh)
            } else {
                SplatMortonReorder.reorder(splats: &sparkSplats)
            }
        }

        let label = name ?? "splats"
        var splatsBuffer = try device.makeTypedBuffer(element: SparkSplat.self, capacity: max(1, sparkSplats.count), options: [.storageModeShared]).labeled("Splats (\(label))")
        splatsBuffer.count = sparkSplats.count
        for (index, splat) in sparkSplats.enumerated() {
            splatsBuffer[index] = splat
        }
        if shDegree > 0 {
            var shBuffer = try device.makeTypedBuffer(values: sh.isEmpty ? [0] : sh, options: [.storageModeShared]).labeled("SHCoefficients (\(label))")
            shBuffer.count = sh.count
            self.init(splats: splatsBuffer, modelTransform: modelTransform, shCoefficients: shBuffer, shDegree: shDegree, opacity: opacity)
        } else {
            self.init(splats: splatsBuffer, modelTransform: modelTransform, opacity: opacity)
        }
    }

    /// The number of SH basis functions (excluding the DC term) for a degree:
    /// degree 1 has 3, degree 2 has 8, and degree 3 has 15.
    private static func shBasisCount(forDegree degree: UInt8) -> Int {
        guard degree > 0 else {
            return 0
        }
        let bands = Int(degree) + 1
        return bands * bands - 1
    }
}

/// Errors from building a ``GPUSplatCloud`` from application-generated data.
public enum GPUSplatCloudError: Error, Equatable {
    /// A splat's spherical-harmonics rows did not match the requested degree.
    case malformedSphericalHarmonics(expectedRows: Int, actualRows: Int)
    case unsupportedSphericalHarmonicsDegree(UInt8)
}
#endif
