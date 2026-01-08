#if os(visionOS)
import SwiftUI

struct ImmersiveModeControlsView: View {
    @Environment(SplatDocumentViewModel.self) private var viewModel
    @Bindable var immersiveState = ImmersiveState.shared
    let onExitImmersive: () -> Void

    private static let rotationOptions: [(String, Float)] = [
        ("0°", 0),
        ("90°", .pi / 2),
        ("180°", .pi),
        ("270°", .pi * 3 / 2)
    ]

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "visionpro")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Immersive Mode")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Rotate X")
                    Picker("Rotate X", selection: $viewModel.modelRotationX) {
                        ForEach(Self.rotationOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                GridRow {
                    Text("Rotate Y")
                    Picker("Rotate Y", selection: $viewModel.modelRotationY) {
                        ForEach(Self.rotationOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                GridRow {
                    Text("Rotate Z")
                    Picker("Rotate Z", selection: $viewModel.modelRotationZ) {
                        ForEach(Self.rotationOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                GridRow {
                    Text("Center")
                    Toggle("Center Model", isOn: $viewModel.centerModel)
                        .labelsHidden()
                }

                GridRow {
                    Text("Scale")
                    HStack {
                        Slider(value: $immersiveState.scale, in: 0.01...2.0)
                        Text(String(format: "%.2f", immersiveState.scale))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
            }
            .frame(maxWidth: 400)

            HStack(spacing: 16) {
                Button {
                    immersiveState.recenter()
                } label: {
                    Label("Recenter", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)

                Button(action: onExitImmersive) {
                    Label("Exit", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
    }
}

#Preview {
    ImmersiveModeControlsView(onExitImmersive: {
        // This line intentionally left blank.
    })
    .environment(SplatDocumentViewModel())
}
#endif
