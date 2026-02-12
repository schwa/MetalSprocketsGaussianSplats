import SwiftUI

// MARK: - Focused Values

struct InspectorVisibilityKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var inspectorVisibility: Binding<Bool>? {
        get { self[InspectorVisibilityKey.self] }
        set { self[InspectorVisibilityKey.self] = newValue }
    }
}

// MARK: - Commands

struct InspectorCommands: Commands {
    @FocusedBinding(\.inspectorVisibility)
    private var showInspector: Bool?

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Show Inspector", isOn: Binding(
                get: { showInspector ?? false },
                set: { showInspector = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(showInspector == nil)

            Divider()
        }
    }
}
