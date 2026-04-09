#if !arch(x86_64)
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Splats
import SwiftUI

struct ContentView: View {
    @State private var cameraMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, 3))
    @State private var renderer: SplatRenderer = .spark
    @State private var frameTimingStatistics: FrameTimingStatistics?

    let splatCloud: GPUSplatCloud<SparkSplat>

    var body: some View {
        SplatView(
            splatCloud: splatCloud,
            cameraMatrix: cameraMatrix
        )
        .splatRenderer(renderer)
        .onFrameTimingChange { frameTimingStatistics = $0 }
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        .overlay(alignment: .top) {
            Picker("Renderer", selection: $renderer) {
                ForEach(SplatRenderer.allCases, id: \.self) { r in
                    Text(r.rawValue.capitalized).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding()
        }
		.overlay(alignment: .bottomTrailing) {
            if let frameTimingStatistics {
                FrameTimingView(statistics: frameTimingStatistics, options: .all)
                .padding()
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
