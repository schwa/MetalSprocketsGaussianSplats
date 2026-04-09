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
    @State private var frameTimingStatistics: FrameTimingStatistics?

    let splatCloud: GPUSplatCloud<SparkSplat>
    @Bindable var demoState: DemoState

    var body: some View {
        SplatView(
            splatCloud: splatCloud,
            cameraMatrix: cameraMatrix
        )
        .splatRenderer(demoState.renderer)
        .onFrameTimingChange { frameTimingStatistics = $0 }
        #if os(visionOS)
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable(), transforms: .init(zoom: { -$0 * 5.0 }))
        #else
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        #endif
        #if !os(visionOS)
        .overlay(alignment: .top) {
            Picker("Renderer", selection: $demoState.renderer) {
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
        #endif
		.overlay(alignment: .bottomTrailing) {
            if let frameTimingStatistics {
                FrameTimingView(statistics: frameTimingStatistics, options: .all)
                .padding()
            }
		}
        .overlay(alignment: .bottomLeading) {
            MatrixView(value: cameraMatrix, style: .number.precision(.fractionLength(2)), colorize: true)
                .font(.caption.monospaced())
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
        #if os(visionOS)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack {
                Picker("Renderer", selection: $demoState.renderer) {
                    ForEach(SplatRenderer.allCases, id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                ImmersiveToggle()
            }
            .padding()
            .glassBackgroundEffect()
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
