#if !arch(x86_64)

import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Metal
import MetalCompilerPluginSupport
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import ZIPFoundation

// MARK: - SOGReaderGPU

/// GPU-accelerated SOG reader, ported from schwa/gaussiansplats-ios.
///
/// Unzips the archive, decodes the SOG's WebP planes concurrently into
/// `.rgba8Uint` textures, and runs a compute kernel
/// (`SOGDecodeShader::decode`) that performs the per-splat de-quantize loop
/// on the GPU, producing the same `SparkSplat` buffer (and flattened
/// higher-order SH float buffer) that `SOGReaderCPU` produces — orders of
/// magnitude faster for multi-million-splat files.
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

    // Cache the decode pipeline per device. Building it compiles the compute
    // function, which is expensive and identical for every load — so we do it
    // once per device and reuse it across all `load` calls.
    private static let pipelineCache = PipelineCache()

    private func decodePipeline() throws -> MTLComputePipelineState {
        try Self.pipelineCache.pipeline(for: device) {
            guard let bundle = Bundle.module.peerBundle(withSuffix: "MetalSprocketsGaussianSplatShaders") else {
                throw SplatsError.resourceCreationFailure("MetalSprocketsGaussianSplatShaders bundle")
            }
            let library = try device.makeDefaultLibrary(bundle: bundle)
            guard let function = library.makeFunction(name: "SOGDecodeShader::decode") else {
                throw SplatsError.resourceCreationFailure("SOGDecodeShader::decode not found")
            }
            let descriptor = MTLComputePipelineDescriptor()
            descriptor.label = "SOGDecode"
            descriptor.computeFunction = function
            return try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        }
    }

    /// - Parameter name: Overrides the buffer label; defaults to the file's name.
    public func load(url: URL, name: String? = nil) throws -> Result {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw SplatsError.failedToExtractZIP
        }

        let metadataData = try Self.extractData(from: archive, filename: "meta.json")
        let metadata = try JSONDecoder().decode(SOGGPUMetadata.self, from: metadataData)

        // Gather the image filenames. WebP decode dominates load time and each
        // image is independent, so we extract serially (cheap) then decode +
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

        // Output buffers. Label them with the source filename so GPU captures
        // identify which cloud each buffer belongs to.
        let cloudName = name ?? url.deletingPathExtension().lastPathComponent
        let count = metadata.count
        let splatsOut = try device.makeTypedBuffer(element: SparkSplat.self, capacity: count, options: [.storageModeShared]).labeled("Splats (\(cloudName))")
        let shFloatCount = max(1, count * shFloatsPerSplat)
        let shOut = try device.makeTypedBuffer(element: Float.self, capacity: shFloatCount, options: [.storageModeShared]).labeled("SHCoefficients (\(cloudName))")

        // Params.
        var params = SOGDecodeParams(
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

        // Pipeline (cached per device).
        let pipeline = try decodePipeline()

        guard let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SplatsError.resourceCreationFailure("SOG decode command encoding")
        }
        queue.label = "SOGDecodeQueue"
        commandBuffer.label = "SOGDecode"
        encoder.label = "SOGDecode"
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params, length: MemoryLayout<SOGDecodeParams>.stride, index: 0)
        encoder.setBuffer(splatsOut.unsafeMTLBuffer, offset: 0, index: 1)
        encoder.setBuffer(shOut.unsafeMTLBuffer, offset: 0, index: 2)
        encoder.setBuffer(scalesCodebook, offset: 0, index: 3)
        encoder.setBuffer(sh0Codebook, offset: 0, index: 4)
        encoder.setBuffer(shNCodebook, offset: 0, index: 5)
        encoder.setTexture(meansLow, index: 0)
        encoder.setTexture(meansHigh, index: 1)
        encoder.setTexture(scales, index: 2)
        encoder.setTexture(quats, index: 3)
        encoder.setTexture(sh0, index: 4)
        encoder.setTexture(shCentroidsTex ?? sh0, index: 5)
        encoder.setTexture(shLabelsTex ?? sh0, index: 6)

        let threadsPerGroup = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let groups = (count + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

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

    /// Extract each image serially (cheap), then decode + upload all of them
    /// concurrently. WebP decode is the dominant cost and each image is
    /// independent, so this parallelizes the bottleneck.
    private func loadTextures(from archive: Archive, filenames: [String]) throws -> [MTLTexture] {
        let blobs = try filenames.map { try Self.extractData(from: archive, filename: $0) }

        let device = self.device
        // Each concurrentPerform iteration writes to a distinct index, so the
        // shared buffer is safe to capture despite being non-Sendable.
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

    /// Decode a SOG image to raw, non-premultiplied RGBA bytes and upload as an
    /// `.rgba8Uint` texture (integer texels; no sRGB / normalization).
    private static func decodeAndUpload(device: MTLDevice, data imageData: Data, filename: String) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil), let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SplatsError.failedToDecodeImage(filename)
        }
        let width = cgImage.width
        let height = cgImage.height

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // CGContext only supports premultiplied (or skip) alpha for 8-bit RGBA,
        // so we draw premultiplied then un-premultiply to recover the original
        // quantized bytes — matching SOGReaderCPU exactly.
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SplatsError.failedToDecodeImage(filename)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            if a > 0, a < 255 {
                let alphaF = Float(a) / 255.0
                pixels[i + 0] = UInt8(min(255, Float(pixels[i + 0]) / alphaF))
                pixels[i + 1] = UInt8(min(255, Float(pixels[i + 1]) / alphaF))
                pixels[i + 2] = UInt8(min(255, Float(pixels[i + 2]) / alphaF))
            }
        }

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

    private static func extractData(from archive: Archive, filename: String) throws -> Data {
        guard let entry = archive[filename] else {
            throw SplatsError.missingTexture(filename)
        }
        var data = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                data.append(chunk)
            }
        } catch {
            throw SplatsError.failedToExtractZIP
        }
        return data
    }
}

// MARK: - Pipeline cache

/// Thread-safe per-device cache of the SOG decode compute pipeline.
private final class PipelineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [ObjectIdentifier: MTLComputePipelineState] = [:]

    func pipeline(for device: MTLDevice, build: () throws -> MTLComputePipelineState) rethrows -> MTLComputePipelineState {
        let key = ObjectIdentifier(device)
        lock.lock()
        defer {
            lock.unlock()
        }
        if let cached = cache[key] {
            return cached
        }
        let pipeline = try build()
        cache[key] = pipeline
        return pipeline
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

private extension Bundle {
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
