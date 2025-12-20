import CoreGraphics
import GeometryLite3D
import ImageIO
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import QuickLookUI
import simd
import Splats
import UniformTypeIdentifiers

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL

        // Render the splat to an image
        let imageData = try renderSplatPreview(url: url)

        let reply = QLPreviewReply(
            dataOfContentType: .png,
            contentSize: CGSize(width: 800, height: 800)
        ) { _ in
            imageData
        }

        return reply
    }

    private func renderSplatPreview(url: URL) throws -> Data {
        let size = CGSize(width: 800, height: 800)

        // Determine content type
        let contentType = UTType(filenameExtension: url.pathExtension)

        // Load splats
        let device = MTLCreateSystemDefaultDevice()!
        var splats: [SparkSplat] = []

        switch contentType {
        case .spz:
            let reader = try SPZReader(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, genericSplat in
                splats.append(SparkSplat(genericSplat))
            }
        case .ply:
            let reader = try PLYSplatReader(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, genericSplat in
                splats.append(SparkSplat(genericSplat))
            }
        case .antimatter15Splat:
            let reader = try Antimatter15Reader(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, genericSplat in
                splats.append(SparkSplat(genericSplat))
            }
        case .sog:
            let reader = try SOGReaderCPU(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, genericSplat in
                splats.append(SparkSplat(genericSplat))
            }
        default:
            throw NSError(
                domain: "PreviewProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported file type: \(contentType?.identifier ?? "unknown")"]
            )
        }

        // Create splat cloud
        let cameraMatrix = simd_float4x4(translation: [0, 0, 5])
        let modelMatrix = simd_float4x4(xRotation: .radians(.pi))

        let splatCloud = try GPUSplatCloud(
            device: device,
            splats: splats,
            cameraMatrix: cameraMatrix,
            modelMatrix: modelMatrix
        )

        // Create projection
        let projection = PerspectiveProjection(
            verticalAngleOfView: .degrees(90),
            depthMode: .standard(zClip: 0.01 ... 1_000)
        )
        let projectionMatrix = projection.projectionMatrix(for: size)

        // Render offscreen
        let renderer = try OffscreenRenderer(size: size)

        let renderPass = try! RenderPass {
            try SparkSplatRenderPipeline(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: SIMD2<Float>(size)
            )
        }

        let rendering = try renderer.render(renderPass)
        let cgImage = try rendering.cgImage

        // Convert to PNG data
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "PreviewProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PreviewProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image"])
        }

        return data as Data
    }
}

// MARK: - UTType extensions

private extension UTType {
    static var sog: UTType {
        UTType(importedAs: "com.playcanvas.sog")
    }

    static var ply: UTType {
        UTType(importedAs: "public.polygon-file-format")
    }

    static var antimatter15Splat: UTType {
        UTType(importedAs: "com.antimatter15.splat")
    }

    static var spz: UTType {
        UTType(importedAs: "com.nianticlabs.spz")
    }
}
