#if !arch(x86_64)
import Cocoa
import GeometryLite3D
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import QuickLookUI
import simd
import Splats
import SwiftUI
import UniformTypeIdentifiers

class PreviewViewController: NSViewController, QLPreviewingController {
    // swiftlint:disable:next async_without_await
    func preparePreviewOfFile(at url: URL) async throws {
        let contentType = UTType(filenameExtension: url.pathExtension)

        // Load splats
        var splats: [SparkSplat] = []

        switch contentType {
        case .spz:
            let reader = try SPZReader(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, extendedSplat in
                splats.append(SparkSplat(extendedSplat.genericSplat))
            }
        case .ply:
            let reader = try PLYSplatReader(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, extendedSplat in
                splats.append(SparkSplat(extendedSplat.genericSplat))
            }
        case .antimatter15Splat:
            let reader = try Antimatter15Reader(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, extendedSplat in
                splats.append(SparkSplat(extendedSplat.genericSplat))
            }
        case .sog:
            let reader = try SOGReaderCPU(url: url)
            splats.reserveCapacity(reader.splatCount)
            try reader.read { _, extendedSplat in
                splats.append(SparkSplat(extendedSplat.genericSplat))
            }
        default:
            throw NSError(
                domain: "PreviewViewController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported file type: \(contentType?.identifier ?? "unknown")"]
            )
        }

        // Create splat cloud
        let modelMatrix = simd_float4x4(xRotation: .radians(.pi))

        let device = _MTLCreateSystemDefaultDevice()
        let splatCloud = try GPUSplatCloud(
            device: device,
            splats: splats,
            modelTransform: modelMatrix
        )

        // Create and host the SwiftUI view
        let previewView = try SplatPreviewView(splatCloud: splatCloud)
        let hostingView = NSHostingView(rootView: previewView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
#endif
