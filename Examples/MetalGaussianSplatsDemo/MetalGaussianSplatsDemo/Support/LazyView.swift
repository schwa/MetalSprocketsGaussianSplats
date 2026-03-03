import SwiftUI

/// A view that defers its content creation until it appears
struct LazyView<Content: View>: View {
    @State private var hasAppeared = false
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if hasAppeared {
                content()
            } else {
                Color.clear
            }
        }
        .onAppear {
            hasAppeared = true
        }
    }
}
