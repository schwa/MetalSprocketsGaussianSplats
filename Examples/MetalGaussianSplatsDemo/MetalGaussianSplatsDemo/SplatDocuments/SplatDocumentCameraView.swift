import SwiftUI

struct SplatDocumentCameraView: View {
    @Environment(SplatDocumentViewModel.self) private var viewModel
    @Environment(\.displayScale) private var displayScale

    private var viewSize: CGSize { viewModel.viewSize }

    private static let rotationOptions: [(String, Float)] = [
        ("0°", 0),
        ("90°", .pi / 2),
        ("180°", .pi),
        ("270°", .pi * 3 / 2)
    ]

    var body: some View {
        @Bindable var viewModel = viewModel
        Section("Camera") {
            Picker("Mode", selection: $viewModel.cameraMode) {
                ForEach(SplatDocumentViewModel.CameraMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        Section("Field of View") {
            Slider(value: $viewModel.verticalAngleOfView, in: 30...120) {
                Text("FOV")
            }
            LabeledContent("FOV", value: "\(Int(viewModel.verticalAngleOfView))°")
        }
        Section("Model Orientation") {
            Picker("Rotate X", selection: $viewModel.modelRotationX) {
                ForEach(Self.rotationOptions, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            Picker("Rotate Y", selection: $viewModel.modelRotationY) {
                ForEach(Self.rotationOptions, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            Picker("Rotate Z", selection: $viewModel.modelRotationZ) {
                ForEach(Self.rotationOptions, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            Toggle("Center Model", isOn: $viewModel.centerModel)
        }
        Section("Viewport") {
            LabeledContent("Size", value: "\(formattedDimension(viewSize.width)) × \(formattedDimension(viewSize.height))")
            LabeledContent("Aspect Ratio", value: aspectRatioString)
            LabeledContent("Megapixels", value: megapixelsString)
            if displayScale != 1 {
                LabeledContent("Scale", value: "\(Int(displayScale))x")
            }
        }
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
