#if os(iOS) || os(macOS)
import MetalSprocketsGaussianSplats
import SwiftUI

struct SceneInspector: View {
    @Binding var document: SplatSceneDocument
    @Environment(SplatViewModel.self) private var viewModel

    private var enabledSplatCount: Int {
        let enabledCloudIDs = Set(document.scene.clouds.filter(\.enabled).map(\.id))
        return viewModel.loadedClouds
            .filter { enabledCloudIDs.contains($0.id) }
            .reduce(into: 0) { $0 += $1.cloud?.count ?? 0 }
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
#endif
