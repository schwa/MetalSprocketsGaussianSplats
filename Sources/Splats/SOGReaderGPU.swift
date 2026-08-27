#if !arch(x86_64)

import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Metal
import MetalCompilerPluginSupport
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import SwiftZipReader

// MARK: - SOGReaderGPU

/// A GPU-accelerated SOG reader, ported from schwa/gaussiansplats-ios.
///
/// The reader unzips the archive. It decodes the SOG WebP planes concurrently
/// into `.rgba8Uint` textures. Then it runs a compute kernel
/// (`SOGDecodeShader::decode`) that does the per-splat de-quantize loop on the
/// GPU. The kernel produces a `SparkSplat` buffer and a flattened higher-order
/// SH float buffer, ready for rendering. This is much faster than a per-splat
/// CPU decode for files with millions of splats.
///
/// `SOGReaderGPU` does not conform to ``SplatReaderProtocol``. That protocol
/// streams CPU-side `ExtendedSplat` values one at a time. This reader needs a
/// `MTLDevice` and produces GPU-resident buffers all at once. It uses the same
/// `read` name, but takes the URL per call. The device is the reader state, not
/// the file.
public struct SOGReaderGPU {
    /// Decoded result, GPU-resident.
    public struct Result {
        public var splats: TypedMTLBuffer<SparkSplat>
        /// Flattened SH coefficients (`count * shFloatsPerSplat` floats), or empty.
        public var shCoefficients: TypedMTLBuffer<Float>
        public var shDegree: UInt8
        public var count: Int
    }

    private let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
    }

    // Cache one Runner (and its element System) per device. A reused Runner
    // keeps the compiled decode pipeline state across `read` calls. Without the
    // cache, each read recompiles the compute function.
    private static let runnerCache = RunnerCache()

    private func decodeKernel() throws -> ComputeKernel {
        guard let bundle = Bundle.module.peerBundle(withSuffix: "MetalSprocketsGaussianSplatShaders") else {
            throw SplatsError.resourceCreationFailure("MetalSprocketsGaussianSplatShaders bundle")
        }
        return try ShaderLibrary(bundle: bundle).namespaced("SOGDecodeShader").function(named: "decode", type: ComputeKernel.self)
    }

    /// Reads a SOG archive and decodes its splat textures on the GPU.
    ///
    /// - Parameters:
    ///   - url: The `.sog` archive to read.
    ///   - name: Overrides the buffer label. The default is the file name.
    public func read(url: URL, name: String? = nil) throws -> Result {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(contentsOf: url)
        } catch {
            throw SplatsError.failedToExtractZIP
        }

        let metadataData = try Self.extractData(from: archive, filename: "meta.json")
        let metadata = try JSONDecoder().decode(SOGGPUMetadata.self, from: metadataData)

        // Gather the image filenames. WebP decode dominates the load time, and
        // each image is independent. Extract serially (cheap), then decode and
        // upload concurrently.
        let hasSH = (metadata.shN?.files.count ?? 0) >= 2
        var filenames = [
            metadata.means.files[0],
            metadata.means.files[1],
            metadata.scales.files[0],
            metadata.quats.files[0],
            metadata.sh0.files[0]
        ]
        if hasSH, let shN = metadata.shN {
            filenames.append(shN.files[0])
            filenames.append(shN.files[1])
        }

        let textures = try loadTextures(from: archive, filenames: filenames)
        let meansLow = textures[0]
        let meansHigh = textures[1]
        let scales = textures[2]
        let quats = textures[3]
        let sh0 = textures[4]
        let shCentroidsTex: MTLTexture? = hasSH ? textures[5] : nil
        let shLabelsTex: MTLTexture? = hasSH ? textures[6] : nil

        let splatTexWidth = meansLow.width

        var shDegree = 0
        var shNumCoeffs = 0
        if hasSH, let shN = metadata.shN {
            shDegree = shN.bands
            shNumCoeffs = [3, 8, 15][shN.bands - 1]
        }

        let shFloatsPerSplat = shNumCoeffs * 3

        // Codebook buffers.
        let scalesCodebook = try makeFloatBuffer(metadata.scales.codebook, label: "scalesCodebook")
        let sh0Codebook = try makeFloatBuffer(metadata.sh0.codebook, label: "sh0Codebook")
        let shNCodebook = try makeFloatBuffer(metadata.shN?.codebook ?? [0], label: "shNCodebook")

        // Output buffers. Label each one with the source filename. The label
        // lets a GPU capture identify which cloud each buffer belongs to.
        let cloudName = name ?? url.deletingPathExtension().lastPathComponent
        let count = metadata.count
        let splatsOut = try device.makeTypedBuffer(element: SparkSplat.self, capacity: count, options: [.storageModeShared]).labeled("Splats (\(cloudName))")
        let shFloatCount = max(1, count * shFloatsPerSplat)
        let shOut = try device.makeTypedBuffer(element: Float.self, capacity: shFloatCount, options: [.storageModeShared]).labeled("SHCoefficients (\(cloudName))")

        let params = SOGDecodeParams(
            count: UInt32(count),
            meansMin: SIMD3<Float>(metadata.means.mins[0], metadata.means.mins[1], metadata.means.mins[2]),
            meansMax: SIMD3<Float>(metadata.means.maxs[0], metadata.means.maxs[1], metadata.means.maxs[2]),
            shDegree: UInt32(shDegree),
            shNumCoeffs: UInt32(shNumCoeffs),
            shFloatsPerSplat: UInt32(shFloatsPerSplat),
            shCentroidsWidth: UInt32(shCentroidsTex?.width ?? 0),
            shEntriesPerRow: 64,
            splatTexWidth: UInt32(splatTexWidth)
        )

        let kernel = try decodeKernel()
        try Self.runnerCache.run(device: device) {
            try ComputePass(label: "SOGDecode") {
                try ComputePipeline(computeKernel: kernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                        .parameter("params", value: params)
                        .parameter("splatsOut", buffer: splatsOut.unsafeMTLBuffer)
                        .parameter("shOut", buffer: shOut.unsafeMTLBuffer)
                        .parameter("scalesCodebook", buffer: scalesCodebook)
                        .parameter("sh0Codebook", buffer: sh0Codebook)
                        .parameter("shNCodebook", buffer: shNCodebook)
                        .parameter("meansLow", texture: meansLow)
                        .parameter("meansHigh", texture: meansHigh)
                        .parameter("scales", texture: scales)
                        .parameter("quats", texture: quats)
                        .parameter("sh0", texture: sh0)
                        .parameter("shCentroids", texture: shCentroidsTex ?? sh0)
                        .parameter("shLabels", texture: shLabelsTex ?? sh0)
                }
            }
        }

        var splatsResult = splatsOut
        splatsResult.count = count
        var shResult = shOut
        shResult.count = shDegree > 0 ? count * shFloatsPerSplat : 0

        return Result(splats: splatsResult, shCoefficients: shResult, shDegree: UInt8(clamping: shDegree), count: count)
    }

    // MARK: - Private helpers

    private func makeFloatBuffer(_ values: [Float], label: String) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(bytes: values, length: values.count * MemoryLayout<Float>.stride, options: [.storageModeShared]) else {
            throw SplatsError.resourceCreationFailure("float buffer \(label)")
        }
        buffer.label = label
        return buffer
    }

    /// Extracts each image serially (cheap), then decodes and uploads all of
    /// them concurrently.
    ///
    /// WebP decode is the dominant cost, and each image is independent. This
    /// parallelizes the bottleneck.
    private func loadTextures(from archive: ZipArchive, filenames: [String]) throws -> [MTLTexture] {
        let blobs = try filenames.map { try Self.extractData(from: archive, filename: $0) }

        let device = self.device
        // Each concurrentPerform iteration writes to a distinct index, so the
        // shared buffer is safe to capture even though it is non-Sendable.
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<DecodeResult>.allocate(capacity: filenames.count)
        defer {
            results.deallocate()
        }
        results.initialize(repeating: .pending)

        DispatchQueue.concurrentPerform(iterations: filenames.count) { i in
            do {
                let texture = try Self.decodeAndUpload(device: device, data: blobs[i], filename: filenames[i])
                results[i] = .success(texture)
            } catch {
                results[i] = .failure(error)
            }
        }

        return try results.map { result in
            switch result {
            case .success(let texture):
                return texture

            case .failure(let error):
                throw error

            case .pending:
                throw SplatsError.failedToDecodeImage("unknown")
            }
        }
    }

    private enum DecodeResult {
        case pending
        case success(MTLTexture)
        case failure(Error)
    }

    /// Decodes a SOG image to raw, non-premultiplied RGBA bytes and uploads it
    /// as an `.rgba8Uint` texture.
    ///
    /// The texture uses integer texels, with no sRGB and no normalization.
    private static func decodeAndUpload(device: MTLDevice, data imageData: Data, filename: String) throws -> MTLTexture {
        let (pixels, width, height) = try SOGImageDecode.decodeRGBA(imageData, filename: filename)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw SplatsError.resourceCreationFailure("texture \(filename)")
        }
        texture.label = filename
        pixels.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else {
                return
            }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: width * 4)
        }
        return texture
    }

    private static func extractData(from archive: ZipArchive, filename: String) throws -> Data {
        guard let entry = archive.entry(named: filename) else {
            throw SplatsError.missingTexture(filename)
        }
        do {
            return try archive.data(for: entry)
        } catch {
            throw SplatsError.failedToExtractZIP
        }
    }
}

// MARK: - Runner cache

/// A thread-safe per-device cache of MetalSprockets Runners.
///
/// A Runner is single-isolation, so the lock is held for the whole `run`.
/// Concurrent decode dispatches serialize here. The dispatch is cheap next to
/// the WebP decode, which stays parallel.
final class RunnerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [ObjectIdentifier: Runner] = [:]

    func run(device: MTLDevice, @ElementBuilder content: () throws -> some Element) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        let key = ObjectIdentifier(device)
        let runner: Runner
        if let cached = cache[key] {
            runner = cached
        } else {
            runner = try Runner(device: device)
            cache[key] = runner
        }
        try runner.run(content())
    }
}

// MARK: - Metadata

private struct SOGGPUMetadata: Codable {
    let count: Int
    let means: MeansMetadata
    let scales: CodebookMetadata
    let quats: QuatsMetadata
    let sh0: CodebookMetadata
    let shN: SHNMetadata?

    struct MeansMetadata: Codable {
        let files: [String]
        let mins: [Float]
        let maxs: [Float]
    }
    struct CodebookMetadata: Codable {
        let files: [String]
        let codebook: [Float]
    }
    struct QuatsMetadata: Codable {
        let files: [String]
    }
    struct SHNMetadata: Codable {
        let count: Int
        let bands: Int
        let codebook: [Float]
        let files: [String]
    }
}

// MARK: - Bundle lookup

extension Bundle {
    func peerBundle(withSuffix suffix: String) -> Bundle? {
        let url = bundleURL.deletingLastPathComponent()
        let fileManager = FileManager()
        guard let filename = try? fileManager.contentsOfDirectory(atPath: url.path).first(where: { $0.hasSuffix("_\(suffix).bundle") }) else {
            return nil
        }
        return Bundle(url: url.appendingPathComponent(filename))
    }
}

#endif
