import SwiftUI

struct ThrowingView<Content: View>: View {
    private let result: Result<Content, Error>

    init(@ViewBuilder content: () throws -> Content) {
        self.result = Result {
            try content()
        }
    }

    var body: some View {
        switch result {
        case .success(let content):
            content
        case .failure(let error):
            ContentUnavailableView("Failed to load", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
        }
    }
}
