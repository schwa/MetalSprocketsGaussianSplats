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
        #if os(visionOS)
        Group {
            if !demoState.isImmersive {
                SplatView(
                    splatCloud: splatCloud,
                    cameraMatrix: cameraMatrix
                )
                .splatRenderer(demoState.renderer)
                .onFrameTimingChange { frameTimingStatistics = $0 }
                // swiftlint:disable:next trailing_closure
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable(), transforms: .init(zoom: { -$0 * 5.0 }))
            } else {
                ContentUnavailableView("Immersive Mode", systemImage: "visionpro", description: Text("Viewing splat in immersive space."))
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack {
                Picker("Model", selection: $demoState.selectedModel) {
                    ForEach(SplatModel.allCases) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Picker("Renderer", selection: $demoState.renderer) {
                    ForEach(SplatRenderer.allCases, id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                ImmersiveToggle(demoState: demoState)
                if demoState.isImmersive, let timing = demoState.immersiveFrameTiming {
                    FrameTimingView(statistics: timing)
                }
            }
            .padding()
            .glassBackgroundEffect()
        }
        #else
        SplatView(
            splatCloud: splatCloud,
            cameraMatrix: cameraMatrix
        )
        .splatRenderer(demoState.renderer)
        .onFrameTimingChange { frameTimingStatistics = $0 }
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        .overlay(alignment: .top) {
            HStack {
                Picker("Model", selection: $demoState.selectedModel) {
                    ForEach(SplatModel.allCases) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Renderer", selection: $demoState.renderer) {
                    ForEach(SplatRenderer.allCases, id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
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
