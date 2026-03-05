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

        switch contentType {
        case .spz:
            let reader = try SPZReader(url: url)
            splatCount = reader.splatCount
            shDegree = reader.shDegree
        case .ply:
            let reader = try PLYSplatReader(url: url)
            splatCount = reader.splatCount
            shDegree = reader.shDegree
        case .antimatter15Splat:
            let reader = try Antimatter15Reader(url: url)
            splatCount = reader.splatCount
            shDegree = 0
        case .sog:
            let reader = try SOGReaderCPU(url: url)
            splatCount = reader.splatCount
            shDegree = UInt8(reader.shDegree)
        default:
            splatCount = 0
            shDegree = 0
        }
    }

    @concurrent
    func computeBounds() async throws -> BoundingBox {
        var bounds = BoundingBox.empty
        switch contentType {
        case .spz:
            let reader = try SPZReader(url: url)
            try reader.read { _, extendedSplat in
                bounds.expand(by: extendedSplat.genericSplat.position)
            }
        case .ply:
            let reader = try PLYSplatReader(url: url)
            try reader.read { _, extendedSplat in
                bounds.expand(by: extendedSplat.genericSplat.position)
            }
        case .antimatter15Splat:
            let reader = try Antimatter15Reader(url: url)
            try reader.read { _, extendedSplat in
                bounds.expand(by: extendedSplat.genericSplat.position)
            }
        case .sog:
            let reader = try SOGReaderCPU(url: url)
            try reader.read { _, extendedSplat in
                bounds.expand(by: extendedSplat.genericSplat.position)
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
    func loadGPUSplatCloud<S>(modelTransform: simd_float4x4 = .identity) throws -> GPUSplatCloud<S> where S: SplatConvertible & SortableSplatProtocol {
        let device = _MTLCreateSystemDefaultDevice()

        var splats: [S] = []
        splats.reserveCapacity(splatCount)

        // Collect SH coefficients if available
        // Each splat's SH is [[Float]] where inner array is [R, G, B] for each basis function
        // We flatten to [Float] as: splat0_coeff0_R, splat0_coeff0_G, splat0_coeff0_B, splat0_coeff1_R, ...
        var shCoefficients: [Float] = []
        var effectiveSHDegree: UInt8 = 0

        switch contentType {
        case .spz:
            let reader = try SPZReader(url: url)
            effectiveSHDegree = reader.shDegree
            let floatsPerSplat = Self.shFloatsPerSplat(degree: effectiveSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(S(extendedSplat.genericSplat))
                if let sh = extendedSplat.sphericalHarmonics {
                    // Flatten [[R,G,B], [R,G,B], ...] to [R,G,B,R,G,B,...]
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }
        case .ply:
            let reader = try PLYSplatReader(url: url)
            effectiveSHDegree = reader.shDegree
            let floatsPerSplat = Self.shFloatsPerSplat(degree: effectiveSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(S(extendedSplat.genericSplat))
                if let sh = extendedSplat.sphericalHarmonics {
                    // Flatten [[R,G,B], [R,G,B], ...] to [R,G,B,R,G,B,...]
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }
        case .antimatter15Splat:
            let reader = try Antimatter15Reader(url: url)
            try reader.read { _, extendedSplat in
                splats.append(S(extendedSplat.genericSplat))
            }
        case .sog:
            let reader = try SOGReaderCPU(url: url)
            effectiveSHDegree = UInt8(reader.shDegree)
            let floatsPerSplat = Self.shFloatsPerSplat(degree: effectiveSHDegree)
            if floatsPerSplat > 0 {
                shCoefficients.reserveCapacity(splatCount * floatsPerSplat)
            }
            try reader.read { _, extendedSplat in
                splats.append(S(extendedSplat.genericSplat))
                if let sh = extendedSplat.sphericalHarmonics {
                    // Flatten [[R,G,B], [R,G,B], ...] to [R,G,B,R,G,B,...]
                    for coeff in sh {
                        shCoefficients.append(contentsOf: coeff)
                    }
                }
            }
        default:
            throw NSError(domain: "SplatCloudDescriptor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported content type: \(contentType?.identifier ?? "nil")"])
        }

        // Create GPU splat cloud with or without SH data
        let splatCloud: GPUSplatCloud<S>
        if !shCoefficients.isEmpty, effectiveSHDegree > 0 {
            splatCloud = try GPUSplatCloud(device: device, splats: splats, modelTransform: modelTransform, shCoefficients: shCoefficients, shDegree: effectiveSHDegree)
        } else {
            splatCloud = try GPUSplatCloud(device: device, splats: splats, modelTransform: modelTransform)
        }

        return splatCloud
    }

    /// Returns the number of floats per splat for a given SH degree
    private static func shFloatsPerSplat(degree: UInt8) -> Int {
        switch degree {
        case 0:
            return 0
        case 1:
            return 3 * 3   // 3 basis functions * 3 channels (RGB)
        case 2:
            return 8 * 3   // 8 basis functions * 3 channels
        case 3:
            return 15 * 3  // 15 basis functions * 3 channels
        default:
            return 0
        }
    }
}
#endif
