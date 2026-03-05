#if os(iOS) || os(macOS)
import GeometryLite3D
import MetalSprocketsGaussianSplats
import simd
import SwiftUI

struct CloudInspector: View {
    // Splat info
    var descriptor: SplatCloudDescriptor?

    // Rotation (both modes)
    @Binding var rotationX: Float
    @Binding var rotationY: Float
    @Binding var rotationZ: Float
    var rotationSectionTitle: String = "Rotation"

    // Single mode: center model
    @Binding var centerModel: Bool
    var showCenterModel: Bool = false

    // Multi mode: cloud properties
    @Binding var displayName: String?
    @Binding var enabled: Bool
    @Binding var opacity: Float
    var showCloudProperties: Bool = false

    // Multi mode: translation
    @Binding var transform: Transform
    var showTranslation: Bool = false

    // Multi mode: delete
    var onDelete: (() -> Void)?

    var body: some View {
        if showCloudProperties {
            Section("Cloud") {
                TextField("Name", text: Binding(
                    get: { displayName ?? "" },
                    set: { displayName = $0.isEmpty ? nil : $0 }
                ))
                Toggle("Enabled", isOn: $enabled)
                VStack(alignment: .leading) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text("\(Int(opacity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $opacity, in: 0...1)
                }
            }
        }

        if showTranslation {
            Section("Position") {
                TransformEditor(transform: $transform)
            }
        }

        if showCenterModel {
            Section("Model Transform") {
                Toggle("Center Model", isOn: $centerModel)
            }
        }

        Section(rotationSectionTitle) {
            RotationPicker(label: "Rotate X", value: $rotationX)
            RotationPicker(label: "Rotate Y", value: $rotationY)
            RotationPicker(label: "Rotate Z", value: $rotationZ)
        }

        SplatCloudInfoSections(descriptor: descriptor)

        if let onDelete {
            Section {
                Button(role: .destructive, action: onDelete) {
                    Label("Remove Cloud", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
#endif
