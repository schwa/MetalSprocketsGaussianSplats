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
                        Text(model.rawValue).tag(model as SplatModel?)
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
        .modifier(SplatImporter(isImporting: $isImporting, demoState: demoState))
        #else
        SplatView(
            splatCloud: splatCloud,
            cameraMatrix: cameraMatrix
        )
        .splatRenderer(demoState.renderer)
        .onFrameTimingChange { frameTimingStatistics = $0 }
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else {
                return false
            }
            Task {
                await demoState.loadCustomSplat(url: url)
            }
            return true
        }
        .overlay(alignment: .top) {
            HStack {
                Picker("Model", selection: $demoState.selectedModel) {
                    ForEach(SplatModel.allCases) { model in
                        Text(model.rawValue).tag(model as SplatModel?)
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
        .modifier(SplatImporter(isImporting: $isImporting, demoState: demoState))

        #endif
    }

    private var loadButton: some View {
        Button("Load\u{2026}") {
            // Cycle through false: macOS can leave the binding stuck true
            // after dismissal, and true -> true never re-presents.
            isImporting = false
            Task { @MainActor in
                isImporting = true
            }
        }
    }
}

private struct SplatImporter: ViewModifier {
    @Binding var isImporting: Bool
    let demoState: DemoState

    private static let splatContentTypes: [UTType] = [.ply, .spz, .sog]

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.splatContentTypes) { result in
                if case .success(let url) = result {
                    // Parsing happens off the main actor, so the importer's
                    // dismissal completes instead of wedging behind a
                    // seconds-long synchronous load (which left it unable
                    // to present a second time).
                    Task {
                        await demoState.loadCustomSplat(url: url)
                    }
                }
            }
            // The alert must sit on a different node than the fileImporter:
            // two presentation modifiers on one node conflict, and the
            // importer silently stops presenting after its first use.
            .background {
                Color.clear
                    .alert("Load Failed", isPresented: Binding(get: { demoState.loadError != nil }, set: { if !$0 { demoState.loadError = nil } })) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(demoState.loadError ?? "")
                    }
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
