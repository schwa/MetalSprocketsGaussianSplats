import SwiftUI

struct ScreenshotSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var width: Int
    @State private var height: Int

    init(defaultWidth: Int, defaultHeight: Int) {
        _width = State(initialValue: defaultWidth)
        _height = State(initialValue: defaultHeight)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Screenshot")
                .font(.headline)

            Form {
                LabeledContent("Width") {
                    TextField("Width", value: $width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Height") {
                    TextField("Height", value: $height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("px")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save…") {
                    // TODO: Implement screenshot saving
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
