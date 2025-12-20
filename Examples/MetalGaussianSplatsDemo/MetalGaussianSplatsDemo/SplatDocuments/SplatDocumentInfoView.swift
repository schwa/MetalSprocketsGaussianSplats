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
        guard viewSize.width > 0, viewSize.height > 0 else {
            return "—"
        }
        let ratio = viewSize.width / viewSize.height
        return String(format: "%.2f:1", ratio)
    }

    private var megapixelsString: String {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return "—"
        }
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

struct AsyncView<T: Sendable, Content>: View where Content: View {
    @State
    private var result: Result<T, Error>?

    let action: @Sendable () async throws -> T
    let content: (T) -> Content

    init(action: @escaping @Sendable () async throws -> T, @ViewBuilder content: @escaping (T) -> Content) {
        self.action = action
        self.content = content
    }

    var body: some View {
        switch result {
        case .none:
            ProgressView()
                .task {
                    do {
                        let value = try await Task.detached {
                            try await action()
                        }.value
                        result = .success(value)
                    } catch {
                        result = .failure(error)
                    }
                }
        case .some(.success(let value)):
            content(value)
        case .some(.failure(let error)):
            ContentUnavailableView(error: error)
        }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(error: Error) {
        self.init("Error", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
    }
}
