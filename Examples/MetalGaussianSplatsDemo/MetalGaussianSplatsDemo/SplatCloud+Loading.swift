#if os(iOS) || (os(macOS) && !arch(x86_64))
import CoreTransferable
import Foundation
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import UniformTypeIdentifiers

// MARK: - Antimatter15GPUSplat Loading

public extension SplatCloud where Splat == Antimatter15GPUSplat {
    /// Combo init - dispatches based on file extension
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
        let antimatterSplats = try await [Antimatter15Splat](importing: url, contentType: .antimatter15Splat)
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
}

// MARK: - SparkGPUSplat Loading

public extension SplatCloud where Splat == SparkGPUSplat {
    /// Combo init - dispatches based on file extension
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
        default:
            throw NSError(domain: "SplatCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported file format: \(url.pathExtension)"])
        }
    }

    convenience init(spzURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = _MTLCreateSystemDefaultDevice()
        let reader = try SPZReader(url: url)
        var splats: [SparkGPUSplat] = []
        splats.reserveCapacity(Int(reader.pointCount))
        try reader.read { spzSplat in
            splats.append(SparkGPUSplat(spzSplat))
        }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(splatURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = _MTLCreateSystemDefaultDevice()
        let data = try Data(contentsOf: url)
        let splatSize = MemoryLayout<Antimatter15Splat>.size
        let count = data.count / splatSize
        var splats: [SparkGPUSplat] = []
        splats.reserveCapacity(count)
        data.withUnsafeBytes { buffer in
            let am15Splats = buffer.bindMemory(to: Antimatter15Splat.self)
            for index in 0..<count {
                splats.append(SparkGPUSplat(am15Splats[index]))
            }
        }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(plyURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = _MTLCreateSystemDefaultDevice()
        let reader = try PLYReader(url: url)
        var splats: [SparkGPUSplat] = []
        splats.reserveCapacity(reader.recordCount)
        try reader.read { record in
            if let sparkSplat = SparkGPUSplat(plyRecord: record) {
                splats.append(sparkSplat)
            }
        }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }

    convenience init(jsonURL url: URL, cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) async throws {
        let device = _MTLCreateSystemDefaultDevice()
        // Load JSON via Antimatter15Splat and convert
        let antimatterSplats = try await [Antimatter15Splat](importing: url, contentType: .json)
        let splats = antimatterSplats.map { SparkGPUSplat($0) }
        try self.init(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }
}

#endif
