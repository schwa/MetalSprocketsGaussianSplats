import simd
import SwiftUI

struct SplatDocumentInfoView: View {
    @Environment(SplatDocumentViewModel.self) private var viewModel

    private var descriptor: SplatCloudDescriptor? { viewModel.descriptor }

    var body: some View {
        SplatCloudInfoSections(descriptor: descriptor)
    }
}

// MARK: - Reusable Info Sections

/// Reusable view showing info about a splat cloud descriptor
struct SplatCloudInfoSections: View {
    let descriptor: SplatCloudDescriptor?

    var body: some View {
        Section("File") {
            LabeledContent("Type", value: descriptor?.fileTypeDescription ?? "—")
            LabeledContent("Size", value: descriptor.map { $0.fileSize.formatted(.byteCount(style: .file)) } ?? "—")
            LabeledContent("Splats", value: descriptor.map { $0.splatCount.formatted() } ?? "—")
            LabeledContent("Bytes/Splat", value: descriptor.map { String(format: "%.1f", $0.bytesPerSplat) } ?? "—")
            LabeledContent("Spherical Harmonics", value: descriptor.map { $0.hasSphericalHarmonics ? "Yes (degree \($0.shDegree))" : "No" } ?? "—")
        }
        Section("Bounds") {
            if let descriptor {
                AsyncView {
                    try await descriptor.computeBounds()
                } content: { bounds in
                    LabeledContent("Min", value: formatVector(bounds.min))
                    LabeledContent("Max", value: formatVector(bounds.max))
                    LabeledContent("Size", value: formatVector(bounds.size))
                    LabeledContent("Center", value: formatVector(bounds.center))
                }
            }
        }
    }

    private func formatVector(_ v: SIMD3<Float>) -> String {
        String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
    }
}
