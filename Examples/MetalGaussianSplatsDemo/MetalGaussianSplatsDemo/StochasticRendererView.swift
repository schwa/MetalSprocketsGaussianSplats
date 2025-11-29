#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Interaction3D
import MetalSprocketsGaussianSplats
import MetalSprocketsSupport
import MetalSprocketsUI
import simd
import SwiftUI

struct StochasticRendererView: View {
    let url: URL?
    let projection: any ProjectionProtocol
    let cameraMatrix: simd_float4x4
    let modelMatrix: simd_float4x4
    var onFrameCompleted: (@Sendable () -> Void)?

    @State private var splatCloud: SplatCloud<SparkSplat>?

    var body: some View {
        ZStack {
            if let splatCloud {
                ThrowingView {
                    try StochasticSplatView(splatCloud: splatCloud, projection: projection, cameraMatrix: cameraMatrix, modelMatrix: modelMatrix, onFrameCompleted: onFrameCompleted)
                }
            }
        }
        .onChange(of: url, initial: true) {
            loadSplatCloud()
        }
    }

    private func loadSplatCloud() {
        guard let url else {
            return
        }
        splatCloud = try! SplatCloud(url: url, cameraMatrix: cameraMatrix)
    }
}

#endif
