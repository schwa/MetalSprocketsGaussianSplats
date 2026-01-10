#if os(iOS) || os(macOS)
import MetalSprocketsGaussianSplats
import SwiftUI

// MARK: - Inspector Tabs

enum SceneInspectorTab: String, CaseIterable {
    case cloud = "Cloud"
    case scene = "Scene"
    case camera = "Camera"
    case render = "Render"
}

// MARK: - Main Inspector View

struct SplatSceneInspectorView: View {
    @Binding var tab: SceneInspectorTab
    @Binding var cloud: SplatScene.CloudReference?
    @Binding var document: SplatSceneDocument
    var onDeleteCloud: (() -> Void)?

    @Environment(SplatSceneViewModel.self) private var viewModel

    private var loadedCloud: SplatSceneViewModel.LoadedCloud? {
        guard let cloudID = cloud?.id else { return nil }
        return viewModel.loadedClouds.first { $0.id == cloudID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker at top
            Picker("Tab", selection: $tab) {
                ForEach(SceneInspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            // Content
            Group {
                switch tab {
                case .cloud:
                    if var cloudBinding = cloud {
                        Form {
                            CloudInspectorContent(cloud: Binding(
                                get: { cloudBinding },
                                set: { cloudBinding = $0; cloud = $0 }
                            ), loadedCloud: loadedCloud, onDelete: onDeleteCloud)
                        }
                        .formStyle(.grouped)
                    } else {
                        ContentUnavailableView("No Selection", systemImage: "cube.transparent", description: Text("Select a cloud to view its details"))
                    }
                case .scene:
                    Form {
                        SceneInspectorContent(document: $document)
                    }
                    .formStyle(.grouped)
                case .camera:
                    Form {
                        CameraInspectorContent()
                    }
                    .formStyle(.grouped)
                case .render:
                    Form {
                        RenderInspectorContent(
                            renderSettings: $document.scene.renderSettings,
                            allCloudsHaveSH: viewModel.allCloudsHaveSphericalHarmonics
                        )
                    }
                    .formStyle(.grouped)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Cloud Inspector

struct CloudInspectorContent: View {
    @Binding var cloud: SplatScene.CloudReference
    let loadedCloud: SplatSceneViewModel.LoadedCloud?
    var onDelete: (() -> Void)?

    var body: some View {
        Section("Cloud") {
            TextField("Name", text: Binding(
                get: { cloud.displayName ?? "" },
                set: { cloud.displayName = $0.isEmpty ? nil : $0 }
            ))

            Toggle("Enabled", isOn: $cloud.enabled)
        }

        Section("Transform") {
            TransformEditor(transform: $cloud.transform)
        }

        Section("Rotation") {
            RotationPicker(label: "Rotate X", value: $cloud.transform.rotation.x)
            RotationPicker(label: "Rotate Y", value: $cloud.transform.rotation.y)
            RotationPicker(label: "Rotate Z", value: $cloud.transform.rotation.z)
        }

        if let loaded = loadedCloud {
            SplatCloudInfoSections(descriptor: loaded.descriptor)
        }

        if let onDelete {
            Section {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Remove Cloud", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Scene Inspector

struct SceneInspectorContent: View {
    @Binding var document: SplatSceneDocument
    @Environment(SplatSceneViewModel.self) private var viewModel

    private var enabledSplatCount: Int {
        let enabledCloudIDs = Set(document.scene.clouds.filter(\.enabled).map(\.id))
        return viewModel.loadedClouds
            .filter { enabledCloudIDs.contains($0.id) }
            .reduce(into: 0) { $0 += $1.cloud.count }
    }

    var body: some View {
        Section("Scene") {
            LabeledContent("Clouds", value: "\(document.scene.clouds.count)")
            LabeledContent("Enabled", value: "\(document.scene.clouds.filter(\.enabled).count)")
            LabeledContent("Splats", value: "\(enabledSplatCount.formatted())")
        }

        Section("Scene Transform") {
            TransformEditor(transform: $document.scene.sceneTransform)
        }

        Section("Scene Orientation") {
            RotationPicker(label: "Rotate X", value: $document.scene.sceneTransform.rotation.x)
            RotationPicker(label: "Rotate Y", value: $document.scene.sceneTransform.rotation.y)
            RotationPicker(label: "Rotate Z", value: $document.scene.sceneTransform.rotation.z)
        }
    }
}

// MARK: - Camera Inspector

struct CameraInspectorContent: View {
    @Environment(SplatSceneViewModel.self) private var viewModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        @Bindable var viewModel = viewModel
        
        Section("Field of View") {
            Slider(value: $viewModel.verticalAngleOfView, in: 30...120) {
                Text("FOV")
            }
            LabeledContent("FOV", value: "\(Int(viewModel.verticalAngleOfView))°")
        }

        Section("Viewport") {
            LabeledContent("Size", value: "\(formattedDimension(viewModel.viewSize.width)) × \(formattedDimension(viewModel.viewSize.height))")
            LabeledContent("Aspect Ratio", value: aspectRatioString)
            LabeledContent("Megapixels", value: megapixelsString)
            if displayScale != 1 {
                LabeledContent("Scale", value: "\(Int(displayScale))x")
            }
        }
    }

    private var aspectRatioString: String {
        guard viewModel.viewSize.width > 0, viewModel.viewSize.height > 0 else {
            return "—"
        }
        let ratio = viewModel.viewSize.width / viewModel.viewSize.height
        return String(format: "%.2f:1", ratio)
    }

    private var megapixelsString: String {
        guard viewModel.viewSize.width > 0, viewModel.viewSize.height > 0 else {
            return "—"
        }
        let pixels = viewModel.viewSize.width * displayScale * viewModel.viewSize.height * displayScale
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

// MARK: - Render Inspector

struct RenderInspectorContent: View {
    @Binding var renderSettings: SplatScene.RenderSettings
    let allCloudsHaveSH: Bool

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                let c = renderSettings.backgroundColor
                guard c.count == 4 else { return .black }
                return Color(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), opacity: Double(c[3]))
            },
            set: { newColor in
                let resolved = newColor.resolve(in: EnvironmentValues())
                renderSettings.backgroundColor = [
                    Float(resolved.red),
                    Float(resolved.green),
                    Float(resolved.blue),
                    Float(resolved.opacity)
                ]
            }
        )
    }

    var body: some View {
        Section("Renderer") {
            ColorPicker("Background", selection: backgroundColorBinding)
        }

        Section("Spherical Harmonics") {
            Toggle("Use Spherical Harmonics", isOn: $renderSettings.useSphericalHarmonics)
                .disabled(!allCloudsHaveSH)

            if !allCloudsHaveSH {
                Label("Not all clouds have SH data", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
#endif
