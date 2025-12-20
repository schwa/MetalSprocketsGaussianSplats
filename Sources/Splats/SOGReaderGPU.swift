#if !arch(x86_64)
import Foundation
import ImageIO
import Metal
import MetalKit
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import UniformTypeIdentifiers
public enum SOGReaderGPU {
    /// Load SOG file and return GPU resources
    public static func load(url: URL, device: MTLDevice) throws -> SOGResources {
        // Extract ZIP to temporary directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Extract ZIP
        try extractZIP(from: url, to: tempDir)

        // Load metadata
        let metadataURL = tempDir.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw SOGError.missingMetadata
        }

        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(SOGMetadata.self, from: metadataData)

        // Create texture loader
        let textureLoader = MTKTextureLoader(device: device)

        // Load textures
        let meansLowTexture = try loadTexture(
            named: metadata.means.files[0],
            from: tempDir,
            loader: textureLoader
        )
        let meansHighTexture = try loadTexture(
            named: metadata.means.files[1],
            from: tempDir,
            loader: textureLoader
        )
        let scalesTexture = try loadTexture(
            named: metadata.scales.files[0],
            from: tempDir,
            loader: textureLoader
        )
        let quatsTexture = try loadTexture(
            named: metadata.quats.files[0],
            from: tempDir,
            loader: textureLoader
        )
        let sh0Texture = try loadTexture(
            named: metadata.sh0.files[0],
            from: tempDir,
            loader: textureLoader
        )

        // Create codebook buffers
        let scalesCodebook = try device.makeTypedBuffer(values: metadata.scales.codebook, options: [])
        let sh0Codebook = try device.makeTypedBuffer(values: metadata.sh0.codebook, options: [])

        // Extract mins/maxs from metadata
        let mins = SIMD3<Float>(metadata.means.mins[0], metadata.means.mins[1], metadata.means.mins[2])
        let maxs = SIMD3<Float>(metadata.means.maxs[0], metadata.means.maxs[1], metadata.means.maxs[2])

        // Extract positions from textures
        let positions = try extractPositions(
            meansLow: meansLowTexture,
            meansHigh: meansHighTexture,
            mins: mins,
            maxs: maxs,
            count: metadata.count,
            device: device
        )

        let positionsBuffer = try device.makeTypedBuffer(values: positions, options: [])

        return SOGResources(
            metadata: metadata,
            positions: positionsBuffer,
            mins: mins,
            maxs: maxs,
            meansLowTexture: meansLowTexture,
            meansHighTexture: meansHighTexture,
            scalesTexture: scalesTexture,
            quatsTexture: quatsTexture,
            sh0Texture: sh0Texture,
            scalesCodebook: scalesCodebook,
            sh0Codebook: sh0Codebook
        )
    }

    // MARK: - Private

    private static func extractZIP(from zipURL: URL, to destURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", destURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SOGError.failedToExtractZIP
        }
    }

    private static func loadTexture(
        named filename: String,
        from directory: URL,
        loader: MTKTextureLoader
    ) throws -> MTLTexture {
        let fileURL = directory.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SOGError.missingTexture(filename)
        }

        #if os(macOS)
        let storageMode = MTLStorageMode.managed.rawValue
        #else
        let storageMode = MTLStorageMode.shared.rawValue
        #endif

        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: storageMode,
            .SRGB: false
        ]

        do {
            return try loader.newTexture(URL: fileURL, options: options)
        } catch {
            throw SOGError.failedToDecodeImage(filename)
        }
    }

    private static func extractPositions(
        meansLow: MTLTexture,
        meansHigh: MTLTexture,
        mins: SIMD3<Float>,
        maxs: SIMD3<Float>,
        count: Int,
        device _: MTLDevice
    ) throws -> [SIMD3<Float>] {
        let width = meansLow.width
        let height = meansLow.height
        let bytesPerRow = width * 4

        var lowData = [UInt8](repeating: 0, count: width * height * 4)
        var highData = [UInt8](repeating: 0, count: width * height * 4)

        meansLow.getBytes(&lowData, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        meansHigh.getBytes(&highData, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(count)

        for i in 0..<count {
            let offset = i * 4

            // Combine upper and lower bytes: (upper << 8) | lower
            let rawX = (UInt16(highData[offset]) << 8) | UInt16(lowData[offset])
            let rawY = (UInt16(highData[offset + 1]) << 8) | UInt16(lowData[offset + 1])
            let rawZ = (UInt16(highData[offset + 2]) << 8) | UInt16(lowData[offset + 2])

            // Normalize and apply bounds
            let tx = Float(rawX) / 65_535.0
            let ty = Float(rawY) / 65_535.0
            let tz = Float(rawZ) / 65_535.0

            let logX = mins.x + tx * (maxs.x - mins.x)
            let logY = mins.y + ty * (maxs.y - mins.y)
            let logZ = mins.z + tz * (maxs.z - mins.z)

            // Inverse log transform
            func invLog(_ v: Float) -> Float {
                let a = abs(v)
                let e = exp(a) - 1.0
                return v < 0 ? -e : e
            }

            let pos = SIMD3<Float>(invLog(logX), invLog(logY), invLog(logZ))
            positions.append(pos)
        }

        return positions
    }
}

/// Compute pass element that converts SOG resources to GenericSplat buffer
/// Use this within a MetalSprockets rendering pipeline
public struct SOGToGenericSplatComputePass: Element {
    var resources: SOGResources
    var outputBuffer: TypedMTLBuffer<GenericSplat>

    @MSState
    var computeKernel: ComputeKernel

    public init(
        resources: SOGResources,
        outputBuffer: TypedMTLBuffer<GenericSplat>
    ) throws {
        self.resources = resources
        self.outputBuffer = outputBuffer

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SOGToGenericSplatConversion")
        self.computeKernel = try shaderLibrary.function(named: "sog_to_generic_splat", type: ComputeKernel.self)
    }

    public var body: some Element {
        get throws {
            try ComputePass(label: "SOG to GenericSplat Conversion") {
                try ComputePipeline(computeKernel: computeKernel) {
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: resources.count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
                    )
                    // Textures
                    .parameter("scalesTex", texture: resources.scalesTexture)
                    .parameter("quatsTex", texture: resources.quatsTexture)
                    .parameter("sh0Tex", texture: resources.sh0Texture)
                    // Input buffers
                    .parameter("positions", buffer: resources.positions.unsafeMTLBuffer)
                    .parameter("scalesCodebook", buffer: resources.scalesCodebook.unsafeMTLBuffer)
                    .parameter("sh0Codebook", buffer: resources.sh0Codebook.unsafeMTLBuffer)
                    // Output buffer
                    .parameter("genericSplats", buffer: outputBuffer.unsafeMTLBuffer)
                    // Uniforms
                    .parameter("splatCount", value: UInt32(resources.count))
                    .parameter("textureWidth", value: UInt32(resources.textureWidth))
                }
            }
        }
    }
}

/// Standalone converter to transform SOG resources into GenericSplat array using GPU compute
@preconcurrency
@MainActor
public struct SOGToGenericSplatConverter {
    private let device: MTLDevice
    private let computeKernel: ComputeKernel

    public init(device: MTLDevice) throws {
        self.device = device

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SOGToGenericSplatConversion")
        self.computeKernel = try shaderLibrary.function(named: "sog_to_generic_splat", type: ComputeKernel.self)
    }

    /// Converts SOG resources to an array of GenericSplat using GPU compute
    public func convert(_ resources: SOGResources) throws -> [GenericSplat] {
        let outputBuffer = try convertToBuffer(resources)
        let pointer = outputBuffer.unsafeMTLBuffer.contents().bindMemory(
            to: GenericSplat.self,
            capacity: resources.count
        )
        return Array(UnsafeBufferPointer(start: pointer, count: resources.count))
    }

    /// Converts SOG resources to a TypedMTLBuffer of GenericSplat (stays on GPU)
    public func convertToBuffer(_ resources: SOGResources) throws -> TypedMTLBuffer<GenericSplat> {
        var outputBuffer = try device.makeTypedBuffer(
            element: GenericSplat.self,
            capacity: resources.count,
            options: .storageModeShared
        )
        outputBuffer.count = resources.count

        let computePass = try ComputePass {
            try ComputePipeline(computeKernel: computeKernel) {
                try ComputeDispatch(
                    threadsPerGrid: MTLSize(width: resources.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
                )
                .parameter("scalesTex", texture: resources.scalesTexture)
                .parameter("quatsTex", texture: resources.quatsTexture)
                .parameter("sh0Tex", texture: resources.sh0Texture)
                .parameter("positions", buffer: resources.positions.unsafeMTLBuffer)
                .parameter("scalesCodebook", buffer: resources.scalesCodebook.unsafeMTLBuffer)
                .parameter("sh0Codebook", buffer: resources.sh0Codebook.unsafeMTLBuffer)
                .parameter("genericSplats", buffer: outputBuffer.unsafeMTLBuffer)
                .parameter("splatCount", value: UInt32(resources.count))
                .parameter("textureWidth", value: UInt32(resources.textureWidth))
            }
        }

        try computePass.run()

        return outputBuffer
    }
}

#endif
