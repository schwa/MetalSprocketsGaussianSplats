import Foundation
import GeometryLite3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import simd
import Splats
import UniformTypeIdentifiers

struct SplatCloudDescriptor: Sendable {
    var url: URL
    var contentType: UTType?
    var fileSize: Int
    var splatCount: Int = 0
    var shDegree: UInt8 = 0

    var bytesPerSplat: Double {
        guard splatCount > 0 else {
            return 0
        }
        return Double(fileSize) / Double(splatCount)
    }

    var hasSphericalHarmonics: Bool {
        shDegree > 0
    }

    var fileTypeDescription: String {
        contentType?.localizedDescription ?? "Unknown"
    }

    init(url: URL) throws {
        self.url = url

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        fileSize = attributes[.size] as? Int ?? 0

        contentType = UTType(filenameExtension: url.pathExtension)

        try timeit("Count calculation.") {
            switch contentType {
            case .spz:
                let reader = try SPZReader(url: url)
                splatCount = reader.splatCount
                shDegree = reader.shDegree
            case .ply:
                let reader = try PLYSplatReader(url: url)
                splatCount = reader.splatCount
                shDegree = 0
            case .antimatter15Splat:
                let reader = try Antimatter15Reader(url: url)
                splatCount = reader.splatCount
                shDegree = 0
            case .sog:
                let reader = try SOGReaderCPU(url: url)
                splatCount = reader.splatCount
                shDegree = 0
            default:
                splatCount = 0
                shDegree = 0
            }
        }
    }

    @concurrent
    func computeBounds() async throws -> BoundingBox {
        var bounds = BoundingBox.empty
        switch contentType {
        case .spz:
            let reader = try SPZReader(url: url)
            try reader.read { _, splat in
                bounds.expand(by: splat.position)
            }
        case .ply:
            let reader = try PLYSplatReader(url: url)
            try reader.read { _, splat in
                bounds.expand(by: splat.position)
            }
        case .antimatter15Splat:
            let reader = try Antimatter15Reader(url: url)
            try reader.read { _, splat in
                bounds.expand(by: splat.position)
            }
        case .sog:
            let reader = try SOGReaderCPU(url: url)
            try reader.read { _, splat in
                bounds.expand(by: splat.position)
            }
        default:
            break
        }
        return bounds
    }
}

#if !arch(x86_64)
import Metal
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

// MARK: - SplatConvertible Protocol

protocol SplatConvertible {
    init(_ splat: GenericSplat)
}

extension SparkSplat: SplatConvertible {}
extension Antimatter15GPUSplat: SplatConvertible {}

// MARK: - GPUSplatCloud Loading

extension SplatCloudDescriptor {
    func loadGPUSplatCloud<S>(cameraMatrix: simd_float4x4 = .identity, modelMatrix: simd_float4x4 = .identity) throws -> GPUSplatCloud<S> where S: SplatConvertible & SortableSplatProtocol {
        let device = _MTLCreateSystemDefaultDevice()

        var splats: [S] = []
        splats.reserveCapacity(splatCount)

        switch contentType {
        case .spz:
            let reader = try SPZReader(url: url)
            try reader.read { _, genericSplat in
                splats.append(S(genericSplat))
            }
        case .ply:
            let reader = try PLYSplatReader(url: url)
            try reader.read { _, genericSplat in
                splats.append(S(genericSplat))
            }
        case .antimatter15Splat:
            let reader = try Antimatter15Reader(url: url)
            try reader.read { _, genericSplat in
                splats.append(S(genericSplat))
            }
        case .sog:
            let reader = try SOGReaderCPU(url: url)
            try reader.read { _, genericSplat in
                splats.append(S(genericSplat))
            }
        default:
            throw NSError(domain: "SplatCloudDescriptor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported content type: \(contentType?.identifier ?? "nil")"])
        }

        return try GPUSplatCloud(device: device, splats: splats, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix)
    }
}
#endif
