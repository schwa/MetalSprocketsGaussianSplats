import simd
import SwiftUI

struct SplatCloudInfoSections: View {
    let descriptor: SplatCloudDescriptor?

    var body: some View {
        Section("File") {
            LabeledContent("Type", value: descriptor?.fileTypeDescription ?? "—")
            LabeledContent("Size", value: descriptor.map { $0.fileSize.formatted(.byteCount(style: .file)) } ?? "—")
            LabeledContent("Splats", value: descriptor.map { $0.splatCount.formatted() } ?? "—")
            LabeledContent("Bytes/Splat", value: descriptor.map { $0.bytesPerSplat.formatted(.number.precision(.fractionLength(1))) } ?? "—")
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
        "(\(v.x.formatted(.number.precision(.fractionLength(2)))), \(v.y.formatted(.number.precision(.fractionLength(2)))), \(v.z.formatted(.number.precision(.fractionLength(2)))))"
    }
}
