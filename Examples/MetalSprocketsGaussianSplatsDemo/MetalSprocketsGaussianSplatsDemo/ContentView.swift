#if !arch(x86_64)
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatsDebug
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsUI
import Splats
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var cameraMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, 3))
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
                splatRenderView
                    .splatRenderer(demoState.renderer)
                .modifier(FrameTimingOverlay())
                // swiftlint:disable:next trailing_closure
                .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable(), transforms: .init(zoom: { -$0 * 5.0 }))
            } else {
                ContentUnavailableView("Immersive Mode", systemImage: "visionpro", description: Text("Viewing splat in immersive space."))
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack {
                modelPicker
                Picker("Renderer", systemImage: "paintbrush", selection: $demoState.renderer) {
                    ForEach(SplatRenderer.allCases.filter { $0 != .pointSplat && $0 != .tileBased }, id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                .pickerStyle(.menu)
                debugPicker
                sortPrecisionPicker
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
            ARSplatView(splatCloud: splatCloud, sortPrecision: demoState.sortPrecision)
                .id(demoState.sortPrecision)
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

    @ViewBuilder
    private var splatRenderView: some View {
        if let debugParams = demoState.debugParams {
            DebugSplatView(splatCloud: splatCloud, cameraMatrix: cameraMatrix, debugParams: debugParams, sortPrecision: demoState.sortPrecision)
                .id(demoState.sortPrecision)
        } else {
            SplatView(splatCloud: splatCloud, cameraMatrix: cameraMatrix, sortPrecision: demoState.sortPrecision)
                .id(demoState.sortPrecision)
        }
    }

    private var debugPicker: some View {
        Picker("Debug", systemImage: "ladybug", selection: $demoState.debugMode) {
            Text("Off").tag(nil as SplatDebugMode?)
            ForEach(SplatDebugMode.allCases.filter { $0 != .cloudIndex }, id: \.self) { mode in
                Text(mode.displayName).tag(mode as SplatDebugMode?)
            }
        }
        .pickerStyle(.menu)
    }

    #if !os(visionOS)
    // Toolbar chrome instead of the floating overlay bar. Applied on macOS too,
    // despite the MTKView blanking in #45.
    private var navigationContent: some View {
        NavigationStack {
            titledSplatSurface
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        modelPicker
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
                        debugPicker
                        sortPrecisionPicker
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
    /// The shared Metal surface: splat view, camera interaction, drag and drop,
    /// loading and timing overlays, and the file importer. Platform chrome
    /// wraps this. The toolbar wraps it on iOS, the floating overlay on macOS.
    private var splatSurface: some View {
        splatRenderView
            .splatRenderer(demoState.renderer)
            .modifier(FrameTimingOverlay())
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
        // Cycle through false first. On macOS the binding can stay stuck true
        // after dismissal, and true -> true never re-presents.
        isImporting = false
        Task { @MainActor in
            isImporting = true
        }
    }

    private var modelPicker: some View {
        Picker("Model", systemImage: "cube", selection: $demoState.selectedModel) {
            // Tag for the custom/generated state so the nil selection is valid.
            if demoState.selectedModel == nil {
                Text(demoState.customModelName ?? "Custom").tag(SplatModel?.none)
            }
            ForEach(SplatModel.allCases) { model in
                Text(model.rawValue).tag(model as SplatModel?)
            }
        }
        .pickerStyle(.menu)
    }

    private var sortPrecisionPicker: some View {
        #if os(visionOS)
        let selection = demoState.isImmersive ? $demoState.immersiveSortPrecision : $demoState.sortPrecision
        #else
        let selection = $demoState.sortPrecision
        #endif
        return Picker("Sort precision", selection: selection) {
            ForEach(SplatSortPrecision.allCases, id: \.self) { precision in
                Text("\(precision.rawValue)-bit").tag(precision)
            }
        }
        .pickerStyle(.menu)
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

/// Owns the frame-timing state locally so per-frame updates invalidate only
/// this subtree, not the toolbar and menus in the enclosing view.
private struct FrameTimingOverlay: ViewModifier {
    @State private var statistics: FrameTimingStatistics?

    func body(content: Content) -> some View {
        content
            .onFrameTimingChange { statistics = $0 }
            .overlay(alignment: .bottomTrailing) {
                if let statistics {
                    FrameTimingView(statistics: statistics, options: .all)
                        .padding()
                }
            }
    }
}

private struct SplatImporter: ViewModifier {
    @Binding var isImporting: Bool
    let demoState: DemoState

    private static let splatContentTypes: [UTType] = [.ply, .antimatter15Splat, .spz, .sog]

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.splatContentTypes) { result in
                if case .success(let url) = result {
                    // Parse off the main actor so the importer dismissal
                    // completes. A synchronous multi-second load wedges the
                    // dialog and stops it from presenting a second time.
                    Task {
                        await demoState.loadCustomSplat(url: url)
                    }
                }
            }
            // Place the alert on a different node than the fileImporter. Two
            // presentation modifiers on one node conflict, and the importer
            // then stops presenting after its first use.
            .background {
                Color.clear
                    .alert("Load Failed", isPresented: Binding(get: { demoState.loadError != nil }, set: { if !$0 { demoState.loadError = nil } })) {
                        Button("OK", role: .cancel) {
                            // Dismissal only. The binding setter clears the error.
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
