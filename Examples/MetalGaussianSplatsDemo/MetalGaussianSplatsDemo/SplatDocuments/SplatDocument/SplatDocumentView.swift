#if os(iOS) || os(macOS)
import SwiftUI

/// A view for displaying a single Gaussian Splat document (iOS/macOS)
/// Delegates to SplatDocumentContentView for consistent UI across document types
struct SplatDocumentView: View {
    let document: SplatDocument
    let fileURL: URL?

    var body: some View {
        SplatDocumentContentView(document: document, fileURL: fileURL)
    }
}
#endif
