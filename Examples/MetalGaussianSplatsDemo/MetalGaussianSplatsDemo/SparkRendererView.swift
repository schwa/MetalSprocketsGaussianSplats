#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsSupport
import MetalSprocketsUI
import simd
import SwiftUI

struct SparkRendererView: View {
    let url: URL?
    let projection: any ProjectionProtocol
    let cameraMatrix: simd_float4x4
    let modelMatrix: simd_float4x4

    @State private var splatCloud: SplatCloud<SparkSplat>?
    @State private var shCoefficients: TypedMTLBuffer<Float>?
    @State private var shDegree: UInt8 = 0

    var body: some View {
        ZStack {
            if let splatCloud {
                SparkSplatView(
                    splatCloud: splatCloud,
                    projection: projection,
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix,
                    shCoefficients: shCoefficients,
                    shDegree: shDegree
                )
            }
        }
        .onChange(of: url, initial: true) {
            Task {
                await loadSplatCloud()
            }
        }
    }

    private func loadSplatCloud() async {
        guard let url else {
            return
        }

        // Use loadWithSH for SPZ files to get SH data
        if url.pathExtension.lowercased() == "spz" {
            let result = try! SplatCloud<SparkSplat>.loadWithSH(url: url, cameraMatrix: cameraMatrix)
            splatCloud = result.splatCloud
            shCoefficients = result.shCoefficients
            shDegree = result.shDegree
        } else {
            splatCloud = try! SplatCloud(url: url, cameraMatrix: cameraMatrix)
            shCoefficients = nil
            shDegree = 0
        }
    }
}

#endif
