#if os(iOS) || (os(macOS) && !arch(x86_64))
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import MetalSprocketsUI
import SwiftUI

struct Antimatter15RendererView: View {
    let url: URL?
    let projection: any ProjectionProtocol
    let cameraMatrix: simd_float4x4
    let modelMatrix: simd_float4x4

    @State private var splatCloud: SplatCloud<Antimatter15GPUSplat>?
    @State private var debugMode: Antimatter15SplatRenderPipeline.DebugMode = .off

    var body: some View {
        Group {
            if let splatCloud {
                Antimatter15SplatView(
                    splatCloud: splatCloud,
                    projection: projection,
                    cameraMatrix: cameraMatrix,
                    modelMatrix: modelMatrix,
                    debugMode: debugMode
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Debug Mode", selection: $debugMode) {
                    Text("Off").tag(Antimatter15SplatRenderPipeline.DebugMode.off)
                    Text("Wireframe").tag(Antimatter15SplatRenderPipeline.DebugMode.wireframe)
                    Text("Filled").tag(Antimatter15SplatRenderPipeline.DebugMode.filled)
                }
            }
        }
        .task {
            await loadSplatCloud()
        }
        .onChange(of: url) {
            Task {
                await loadSplatCloud()
            }
        }
    }

    private func loadSplatCloud() async {
        guard let url else {
            return
        }
        splatCloud = try! await SplatCloud(url: url, cameraMatrix: cameraMatrix)
    }
}

#endif
