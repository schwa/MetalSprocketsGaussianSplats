#if os(iOS) || os(macOS)
import SwiftUI

// MARK: - Transform Editor

struct TransformEditor: View {
    @Binding var transform: Transform
    var nudgeAmount: Float = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NudgeableFloatField("X", value: $transform.translation.x, nudgeAmount: nudgeAmount)
            NudgeableFloatField("Y", value: $transform.translation.y, nudgeAmount: nudgeAmount)
            NudgeableFloatField("Z", value: $transform.translation.z, nudgeAmount: nudgeAmount)
        }
    }
}

// MARK: - Rotation Picker

struct RotationPicker: View {
    let label: String
    @Binding var value: Float

    private static let rotationOptions: [(String, Float)] = [
        ("0°", 0),
        ("90°", .pi / 2),
        ("180°", .pi),
        ("270°", .pi * 3 / 2)
    ]

    var body: some View {
        Picker(label, selection: $value) {
            ForEach(Self.rotationOptions, id: \.1) { optionLabel, optionValue in
                Text(optionLabel).tag(optionValue)
            }
        }
    }
}

// MARK: - Nudgeable Float Field

struct NudgeableFloatField: View {
    let label: String
    @Binding var value: Float
    var nudgeAmount: Float = 0.5

    init(_ label: String, value: Binding<Float>, nudgeAmount: Float = 0.5) {
        self.label = label
        self._value = value
        self.nudgeAmount = nudgeAmount
    }

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 20, alignment: .leading)

            Button {
                value -= nudgeAmount
            } label: {
                Image(systemName: "minus")
                    .accessibilityLabel("Decrease")
            }
            .buttonStyle(.borderless)

            TextField("", value: $value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)

            Button {
                value += nudgeAmount
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Increase")
            }
            .buttonStyle(.borderless)
        }
    }
}

#endif
