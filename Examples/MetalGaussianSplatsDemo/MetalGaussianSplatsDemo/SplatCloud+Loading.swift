#if os(iOS) || (os(macOS) && !arch(x86_64))
import CoreTransferable
import Foundation
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import Splats
import UniformTypeIdentifiers

// MARK: - Antimatter15GPUSplat Loading

public extension SplatCloud where Splat == Antimatter15GPUSplat {
    /// Combo init - dispatches based on file extension
    @MainActor
    convenience init(url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        switch url.pathExtension.lowercased() {
        case "spz":
            try await self.init(spzURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "splat":
            try await self.init(splatURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "ply":
            try await self.init(plyURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "json":
            try await self.init(jsonURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "sog":
            try self.init(sogURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        default:
            throw NSError(domain: "SplatCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file format: \(url.pathExtension)"])
        }
    }

    convenience init(spzURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = MTLCreateSystemDefaultDevice()!
        let antimatterSplats = try await [Antimatter15Splat](importing: url, contentType: .spz)
        let gpuSplats = antimatterSplats.map(Antimatter15GPUSplat.init)
        try self.init(device: device, splats: gpuSplats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(splatURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = MTLCreateSystemDefaultDevice()!
        let antimatterSplats = try await [Antimatter15Splat](importing: url, contentType: UTType.antimatter15Splat)
        let gpuSplats = antimatterSplats.map(Antimatter15GPUSplat.init)
        try self.init(device: device, splats: gpuSplats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(plyURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = MTLCreateSystemDefaultDevice()!
        let antimatterSplats = try await [Antimatter15Splat](importing: url, contentType: .ply)
        let gpuSplats = antimatterSplats.map(Antimatter15GPUSplat.init)
        try self.init(device: device, splats: gpuSplats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(jsonURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = MTLCreateSystemDefaultDevice()!
        let antimatterSplats = try await [Antimatter15Splat](importing: url, contentType: .json)
        let gpuSplats = antimatterSplats.map(Antimatter15GPUSplat.init)
        try self.init(device: device, splats: gpuSplats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    @MainActor
    convenience init(sogURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws {
        let device = MTLCreateSystemDefaultDevice()!
        let resources = try SOGReaderGPU.load(url: url, device: device)
        let converter = try SOGToGenericSplatConverter(device: device)
        let genericSplats = try converter.convert(resources)
        let gpuSplats = genericSplats.map(Antimatter15GPUSplat.init)
        try self.init(device: device, splats: gpuSplats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }
}

// MARK: - SparkGPUSplat Loading

public extension SplatCloud where Splat == SparkGPUSplat {
    /// Combo init - dispatches based on file extension
    @MainActor
    convenience init(url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws {
        switch url.pathExtension.lowercased() {
        case "spz":
            try self.init(spzURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "splat":
            try self.init(splatURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "ply":
            try self.init(plyURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "json":
            try self.init(jsonURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        case "sog":
            try self.init(sogURL: url, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        default:
            throw NSError(domain: "SplatCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file format: \(url.pathExtension)"])
        }
    }

    convenience init(spzURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws {
        let device = _MTLCreateSystemDefaultDevice()
        let reader = try Splats.SPZReader(url: url)
        var splats: [SparkGPUSplat] = []
        splats.reserveCapacity(reader.splatCount)
        try reader.read { _, genericSplat in
            splats.append(SparkGPUSplat(genericSplat))
        }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    /// Load SPZ file and extract spherical harmonics if available
    /// Note: SH extraction not yet supported with GenericSplat
    static func loadWithSH(url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws -> (splatCloud: SplatCloud<SparkGPUSplat>, shCoefficients: TypedMTLBuffer<Float>?, shDegree: UInt8) {
        let device = _MTLCreateSystemDefaultDevice()
        let reader = try Splats.SPZReader(url: url)

        var gpuSplats: [SparkGPUSplat] = []
        gpuSplats.reserveCapacity(reader.splatCount)

        try reader.read { _, genericSplat in
            gpuSplats.append(SparkGPUSplat(genericSplat))
        }

        let splatCloud = try SplatCloud(device: device, splats: gpuSplats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)

        // TODO: SH extraction not yet supported with GenericSplat
        return (splatCloud, nil, 0)
    }

    convenience init(splatURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws {
        let device = _MTLCreateSystemDefaultDevice()
        let reader = try Antimatter15Reader(url: url)
        var splats: [SparkGPUSplat] = []
        splats.reserveCapacity(reader.splatCount)
        try reader.read { _, genericSplat in
            splats.append(SparkGPUSplat(genericSplat))
        }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(plyURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws {
        let device = _MTLCreateSystemDefaultDevice()
        let reader = try PLYSplatReader(url: url)
        var splats: [SparkGPUSplat] = []
        splats.reserveCapacity(reader.splatCount)
        try reader.read { _, genericSplat in
            splats.append(SparkGPUSplat(genericSplat))
        }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(jsonURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws {
        let device = _MTLCreateSystemDefaultDevice()
        // Load JSON as GenericSplat and convert
        let genericSplats = try JSONDecoder().decode([GenericSplat].self, from: Data(contentsOf: url))
        let splats = genericSplats.map { SparkGPUSplat($0) }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    @MainActor
    convenience init(sogURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws {
        let device = _MTLCreateSystemDefaultDevice()
        let resources = try SOGReaderGPU.load(url: url, device: device)
        let converter = try SOGToGenericSplatConverter(device: device)
        let genericSplats = try converter.convert(resources)
        let splats = genericSplats.map(SparkGPUSplat.init)
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }
}

#endif
