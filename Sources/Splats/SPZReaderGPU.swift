#if !arch(x86_64)
import Foundation
@preconcurrency import Metal
import MetalCompilerPluginSupport
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

// MARK: - SPZReaderGPU

/// GPU-accelerated SPZ reader. The container is still decompressed on the CPU
/// (gzip for v2/v3, parallel ZSTD for v4 — there is no GPU gunzip/zstd), but the
/// per-splat unpack loop — the bottleneck for multi-million-splat files — runs
/// on the GPU via the `SPZUnpackShader::unpack` compute kernel, producing a
/// `SparkSplat` buffer (and flattened higher-order SH floats) directly.
///
/// Like ``SOGReaderGPU``, this does not conform to ``SplatReaderProtocol``: it
/// needs an `MTLDevice` and produces GPU-resident buffers wholesale.
public struct SPZReaderGPU {
    /// Decoded result, GPU-resident.
    public struct Result {
        public var splats: TypedMTLBuffer<SparkSplat>
        /// Flattened SH coefficients (`count * shCoeffCount * 3` floats), or empty.
        public var shCoefficients: TypedMTLBuffer<Float>
        public var shDegree: UInt8
        public var count: Int
    }

    private let device: MTLDevice

    public init(device: MTLDevice) {
        self.device = device
    }

    private static let runnerCache = RunnerCache()

    private func unpackKernel() throws -> ComputeKernel {
        guard let bundle = Bundle.module.peerBundle(withSuffix: "MetalSprocketsGaussianSplatShaders") else {
            throw SplatsError.resourceCreationFailure("MetalSprocketsGaussianSplatShaders bundle")
        }
        return try ShaderLibrary(bundle: bundle).namespaced("SPZUnpackShader").function(named: "unpack", type: ComputeKernel.self)
    }

    public func read(url: URL, name: String? = nil) throws -> Result {
        try read(data: Data(contentsOf: url), name: name ?? url.deletingPathExtension().lastPathComponent)
    }

    public func read(data: Data, name: String? = nil) throws -> Result {
        let reader = try SPZReader(data: data)
        let layout = try reader.sectionLayout()
        let count = layout.count
        let shFloatsPerSplat = layout.shCoeffCount * 3
        let cloudName = name ?? "splats"

        // Upload the full decompressed payload; SectionLayout offsets already
        // account for the (v2/v3) header, so they index the buffer directly.
        let payload = reader.decompressedData
        guard let payloadBuffer = payload.withUnsafeBytes({ raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: [.storageModeShared])
        }) else {
            throw SplatsError.resourceCreationFailure("SPZ payload buffer")
        }
        payloadBuffer.label = "SPZ payload (\(cloudName))"

        let splatsOut = try device.makeTypedBuffer(element: SparkSplat.self, capacity: max(count, 1), options: [.storageModeShared]).labeled("Splats (\(cloudName))")
        let shFloatCount = max(1, count * shFloatsPerSplat)
        let shOut = try device.makeTypedBuffer(element: Float.self, capacity: shFloatCount, options: [.storageModeShared]).labeled("SHCoefficients (\(cloudName))")

        let params = SPZDecodeParams(
            count: UInt32(count),
            shCoeffCount: UInt32(layout.shCoeffCount),
            fractionalBits: UInt32(layout.fractionalBits),
            rotationBytes: UInt32(layout.rotationBytes),
            positionsOffset: UInt32(layout.positionsOffset),
            alphasOffset: UInt32(layout.alphasOffset),
            colorsOffset: UInt32(layout.colorsOffset),
            scalesOffset: UInt32(layout.scalesOffset),
            rotationsOffset: UInt32(layout.rotationsOffset),
            shOffset: UInt32(layout.shOffset)
        )

        let kernel = try unpackKernel()
        try Self.runnerCache.run(device: device) {
            try ComputePass(label: "SPZUnpack") {
                try ComputePipeline(computeKernel: kernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: max(count, 1), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                        .parameter("p", value: params)
                        .parameter("payload", buffer: payloadBuffer)
                        .parameter("splatsOut", buffer: splatsOut.unsafeMTLBuffer)
                        .parameter("shOut", buffer: shOut.unsafeMTLBuffer)
                }
            }
        }

        var splatsResult = splatsOut
        splatsResult.count = count
        var shResult = shOut
        shResult.count = layout.shCoeffCount > 0 ? count * shFloatsPerSplat : 0

        return Result(splats: splatsResult, shCoefficients: shResult, shDegree: reader.shDegree, count: count)
    }
}
#endif
