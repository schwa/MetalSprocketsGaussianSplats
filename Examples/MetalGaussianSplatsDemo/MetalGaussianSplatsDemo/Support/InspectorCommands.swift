import SwiftUI

// MARK: - Inspector Tab Enum (moved to shared location)

enum InspectorTab: String, CaseIterable {
    case info = "Info"
    case render = "Render"
    case camera = "Camera"
}

// MARK: - Focused Values

struct InspectorVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct InspectorTabKey: FocusedValueKey {
    typealias Value = Binding<InspectorTab>
}

extension FocusedValues {
    var inspectorVisibility: Binding<Bool>? {
        get { self[InspectorVisibilityKey.self] }
        set { self[InspectorVisibilityKey.self] = newValue }
    }

    var inspectorTab: Binding<InspectorTab>? {
        get { self[InspectorTabKey.self] }
        set { self[InspectorTabKey.self] = newValue }
    }
}

// MARK: - Commands

struct InspectorCommands: Commands {
    @FocusedBinding(\.inspectorVisibility)
    private var showInspector: Bool?

    @FocusedBinding(\.inspectorTab)
    private var inspectorTab: InspectorTab?

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Show Inspector", isOn: Binding(
                get: { showInspector ?? false },
                set: { showInspector = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(showInspector == nil)

            Button("Show Info") {
                showInspector = true
                inspectorTab = .info
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(showInspector == nil)

            Button("Show Render Settings") {
                showInspector = true
                inspectorTab = .render
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(showInspector == nil)

            Button("Show Camera") {
                showInspector = true
                inspectorTab = .camera
            }
            .keyboardShortcut("3", modifiers: [.command, .option])
            .disabled(showInspector == nil)

            Divider()
        }
    }
}
