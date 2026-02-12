#if os(iOS) || os(macOS)
import SwiftUI

/// View for editing and rendering a splat scene with multiple clouds
/// Delegates to UnifiedDocumentView for consistent UI across document types
struct SplatSceneView: View {
    @Binding var document: SplatSceneDocument

    var body: some View {
        UnifiedDocumentView(document: $document)
    }
}
#endif
