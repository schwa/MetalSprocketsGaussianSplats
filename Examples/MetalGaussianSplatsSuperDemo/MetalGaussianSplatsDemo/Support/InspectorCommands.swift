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

    private var menuTitle: String {
        (showInspector ?? false) ? "Hide Inspector" : "Show Inspector"
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(menuTitle) {
                showInspector?.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(showInspector == nil)

            Divider()
        }
    }
}
