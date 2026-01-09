import simd
import SwiftUI

struct SplatDocumentInfoView: View {
    @Environment(SplatDocumentViewModel.self) private var viewModel

    private var descriptor: SplatCloudDescriptor? { viewModel.descriptor }

    var body: some View {
        SplatCloudInfoSections(descriptor: descriptor)
    }
}
