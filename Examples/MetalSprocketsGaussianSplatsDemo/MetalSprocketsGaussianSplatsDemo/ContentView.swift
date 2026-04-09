#if !arch(x86_64)
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Splats
import SwiftUI

struct ContentView: View {
    @State private var cameraMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, 3))
    @State private var renderer: SplatRenderer = .spark

    let splatCloud: GPUSplatCloud<SparkSplat>

    var body: some View {
        SplatView(
            splatCloud: splatCloud,
            cameraMatrix: cameraMatrix
        )
        .splatRenderer(renderer)
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        .toolbar {
            ToolbarItem {
                Picker("Renderer", selection: $renderer) {
                    ForEach(SplatRenderer.allCases, id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        #if os(visionOS)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            ImmersiveToggle()
        }
        #endif
    }
}


#else
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Gaussian splat rendering requires Apple Silicon.")
    }
}
#endif
