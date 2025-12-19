import simd
import SwiftUI

struct SplatDocumentInfoView: View {
    @Environment(SplatDocumentViewModel.self) private var viewModel
    @Environment(\.displayScale) private var displayScale

    private var descriptor: SplatCloudDescriptor? { viewModel.descriptor }
    private var viewSize: CGSize { viewModel.viewSize }

    var body: some View {
        Section("File") {
            LabeledContent("Type", value: descriptor?.fileTypeDescription ?? "—")
            LabeledContent("Size", value: descriptor.map { $0.fileSize.formatted(.byteCount(style: .file)) } ?? "—")
            LabeledContent("Splats", value: descriptor.map { $0.splatCount.formatted() } ?? "—")
            LabeledContent("Bytes/Splat", value: descriptor.map { String(format: "%.1f", $0.bytesPerSplat) } ?? "—")
            LabeledContent("Spherical Harmonics", value: descriptor.map { $0.hasSphericalHarmonics ? "Yes (degree \($0.shDegree))" : "No" } ?? "—")
        }
        Section("Bounds") {
            LabeledContent("Min", value: descriptor.map { formatVector($0.boundingBox.min) } ?? "—")
            LabeledContent("Max", value: descriptor.map { formatVector($0.boundingBox.max) } ?? "—")
            LabeledContent("Size", value: descriptor.map { formatVector($0.boundingBox.size) } ?? "—")
            LabeledContent("Center", value: descriptor.map { formatVector($0.boundingBox.center) } ?? "—")
        }
        Section("Window") {
            LabeledContent("Size", value: "\(formattedDimension(viewSize.width)) × \(formattedDimension(viewSize.height))")
            LabeledContent("Aspect Ratio", value: aspectRatioString)
            LabeledContent("Megapixels", value: megapixelsString)
            if displayScale != 1 {
                LabeledContent("Scale", value: "\(Int(displayScale))x")
            }
        }
    }

    private func formatVector(_ v: SIMD3<Float>) -> String {
        String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    }

    private var aspectRatioString: String {
        guard viewSize.width > 0, viewSize.height > 0 else { return "—" }
        let ratio = viewSize.width / viewSize.height
        return String(format: "%.2f:1", ratio)
    }

    private var megapixelsString: String {
        guard viewSize.width > 0, viewSize.height > 0 else { return "—" }
        let pixels = viewSize.width * displayScale * viewSize.height * displayScale
        let megapixels = pixels / 1_000_000
        return String(format: "%.2f MP", megapixels)
    }

    private func formattedDimension(_ value: CGFloat) -> String {
        let pts = Int(value)
        if displayScale == 1 {
            return "\(pts)"
        }
        let px = Int(value * displayScale)
        return "\(pts) (\(px))"
    }
}
