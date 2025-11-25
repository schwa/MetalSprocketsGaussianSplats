#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsSupport
import MetalSprocketsUI
import simd
import SwiftUI

struct TileBasedDemoView: View {
    let url: URL?
    let projection: any ProjectionProtocol
    let cameraMatrix: simd_float4x4
    let modelMatrix: simd_float4x4

    @State private var splatCloud: SplatCloud<SparkSplat>?
    @State private var debugTileOverflow = false
    @State private var debugTileBorders = false

    var body: some View {
        ZStack {
            if let splatCloud {
                TileBasedSplatView(
                    splatCloud: splatCloud,
                    projection: projection,
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix,
                    debugTileOverflow: debugTileOverflow,
                    debugTileBorders: debugTileBorders
                )
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading) {
                Toggle("Tile Overflow", isOn: $debugTileOverflow)
                Toggle("Tile Borders", isOn: $debugTileBorders)
            }
            .toggleStyle(.switch)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
        .onChange(of: url, initial: true) {
            Task {
                loadSplatCloud()
            }
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
