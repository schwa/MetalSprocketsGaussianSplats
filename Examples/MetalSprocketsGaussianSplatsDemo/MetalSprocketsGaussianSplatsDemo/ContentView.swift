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
    #if os(iOS)
    @State private var isARMode = false
    #endif

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
                generateMenu
                ImmersiveToggle(demoState: demoState)
                if demoState.isImmersive, let timing = demoState.immersiveFrameTiming {
                    FrameTimingView(statistics: timing)
                }
            }
            .padding()
            .glassBackgroundEffect()
        }
        .modifier(SplatImporter(isImporting: $isImporting, demoState: demoState))
        #elseif os(iOS)
        if isARMode {
            ARSplatView(splatCloud: splatCloud)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    Button("Exit AR", systemImage: "arkit") {
                        isARMode = false
                    }
                    .buttonStyle(.bordered)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    .padding()
                }
        } else {
            navigationContent
        }
        #else
        navigationContent
        #endif
    }

    #if !os(visionOS)
    // Toolbar chrome instead of the floating overlay bar. Intentionally also
    // on macOS despite the MTKView blanking reported in #45 - debugging that
    // as it comes up.
    private var navigationContent: some View {
        NavigationStack {
            titledSplatSurface
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Picker("Model", systemImage: "cube", selection: $demoState.selectedModel) {
                            ForEach(SplatModel.allCases) { model in
                                Text(model.rawValue).tag(model as SplatModel?)
                            }
                        }
                        .pickerStyle(.menu)
                        Button("Load\u{2026}", systemImage: "folder") {
                            presentImporter()
                        }
                        generateMenu
                        Picker("Renderer", systemImage: "paintbrush", selection: $demoState.renderer) {
                            ForEach(SplatRenderer.allCases, id: \.self) { r in
                                Text(r.rawValue.capitalized).tag(r)
                            }
                        }
                        .pickerStyle(.menu)
                        #if os(iOS)
                        Button("AR", systemImage: "arkit") {
                            isARMode = true
                        }
                        #endif
                    }
                }
        }
    }

    @ViewBuilder
    private var titledSplatSurface: some View {
        let titled = splatSurface
            .navigationTitle(demoState.customModelName ?? demoState.selectedModel?.rawValue ?? "Splats")
        #if os(iOS)
        titled
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
        #else
        titled
        #endif
    }
    #endif

    #if !os(visionOS)
    /// The shared Metal surface: splat view, camera interaction, drag & drop,
    /// loading/timing overlays, and the file importer. Platform chrome
    /// (toolbar on iOS, floating overlay on macOS) wraps this.
    private var splatSurface: some View {
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
        .overlay(alignment: .bottomTrailing) {
            if let frameTimingStatistics {
                FrameTimingView(statistics: frameTimingStatistics, options: .all)
                    .padding()
            }
        }
        .overlay {
            if demoState.isLoading {
                ProgressView("Loading\u{2026}")
                    .padding(16)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .modifier(SplatImporter(isImporting: $isImporting, demoState: demoState))
    }

    #endif

    private func presentImporter() {
        // Cycle through false: macOS can leave the binding stuck true
        // after dismissal, and true -> true never re-presents.
        isImporting = false
        Task { @MainActor in
            isImporting = true
        }
    }

    private var generateMenu: some View {
        Menu("Generate") {
            ForEach(SplatGenerator.presetCounts, id: \.self) { count in
                Button("Sphere \(SplatGenerator.label(for: count))") {
                    Task {
                        await demoState.generateSplats(count: count)
                    }
                }
            }
        }
        .fixedSize()
    }

    private var loadButton: some View {
        Button("Load\u{2026}") {
            presentImporter()
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
                        Button("OK", role: .cancel) {
                            // Dismissal only; the binding's setter clears the error.
                        }
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
