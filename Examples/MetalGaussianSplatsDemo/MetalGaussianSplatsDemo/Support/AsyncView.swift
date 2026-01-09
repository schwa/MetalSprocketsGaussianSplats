import SwiftUI

/// A view that loads async content and displays it when ready
struct AsyncView<T: Sendable, Content>: View where Content: View {
    @State
    private var result: Result<T, Error>?

    let action: @Sendable () async throws -> T
    let content: (T) -> Content

    init(action: @escaping @Sendable () async throws -> T, @ViewBuilder content: @escaping (T) -> Content) {
        self.action = action
        self.content = content
    }

    var body: some View {
        switch result {
        case .none:
            ProgressView()
                .task {
                    do {
                        let value = try await Task.detached {
                            try await action()
                        }.value
                        result = .success(value)
                    } catch {
                        result = .failure(error)
                    }
                }
        case .some(.success(let value)):
            content(value)
        case .some(.failure(let error)):
            ContentUnavailableView(error: error)
        }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(error: Error) {
        self.init("Error", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
    }
}
