#if !arch(x86_64)
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Splats
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var cameraMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, 3))
    @State private var frameTimingStatistics: FrameTimingStatistics?
    @State private var isImporting = false

    private static let splatContentTypes: [UTType] = [.ply, .spz, .sog]

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
                loadButton
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
                loadButton
                if let name = demoState.customModelName {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                }
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

    private var loadButton: some View {
        Button("Load\u{2026}") {
            isImporting = true
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.splatContentTypes) { result in
            if case .success(let url) = result {
                demoState.loadCustomSplat(url: url)
            }
        }
        .alert("Load Failed", isPresented: Binding(get: { demoState.loadError != nil }, set: { if !$0 { demoState.loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(demoState.loadError ?? "")
        }
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
