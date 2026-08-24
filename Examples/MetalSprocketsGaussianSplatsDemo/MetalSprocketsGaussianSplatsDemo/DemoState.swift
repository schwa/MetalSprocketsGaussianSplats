#if !arch(x86_64)
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Splats
#if os(visionOS)
import MetalSprocketsUI
#endif
import Observation
import os

enum SplatModel: String, CaseIterable, Identifiable {
    case helmet = "Helmet"
    case lion = "Lion"
    case tomatoes = "Tomatoes"

    var id: String { rawValue }

    var resourceName: String {
        switch self {
        case .helmet:
            "Helmet"
        case .lion:
            "lion.v3"
        case .tomatoes:
            "tomatoes.v4"
        }
    }

    var resourceExtension: String {
        switch self {
        case .helmet:
            "sog"
        case .lion, .tomatoes:
            "spz"
        }
    }
}

@Observable
class DemoState {
    var renderer: SplatRenderer = .sparkGPU {
        didSet {
            if renderer != .sparkGPU {
                debugMode = nil
            }
        }
    }
    var debugMode: SplatDebugMode? {
        didSet {
            if debugMode != nil {
                renderer = .sparkGPU
            }
        }
    }

    var debugParams: DebugParams? {
        switch debugMode {
        case .distanceFromCenter:
            var params = DebugDistanceParams()
            params.center = .zero
            params.maxDistance = 5
            return .distance(params)
        case .splatSize:
            var params = DebugSizeParams()
            params.minSize = 0
            params.maxSize = 1
            return .size(params)
        case .depth:
            var params = DebugDepthParams()
            params.minDepth = 0
            params.maxDepth = 20
            return .depth(params)
        case .opacity:
            return .opacity
        case .normal:
            return .normal
        case .aspectRatio:
            var params = DebugAspectRatioParams()
            params.minRatio = 1
            params.maxRatio = 10
            return .aspectRatio(params)
        case .cloudIndex:
            return nil
        case nil:
            return nil
        }
    }
    /// The selected bundled model. nil while a user-loaded file is shown.
    var selectedModel: SplatModel? = .tomatoes {
        didSet {
            if let selectedModel, selectedModel != oldValue {
                customModelName = nil
                reloadSplatCloud(model: selectedModel)
            }
        }
    }
    /// Display name of a user-loaded splat file. nil when a bundled model is shown.
    private(set) var customModelName: String?
    var loadError: String?
    /// True while a user-picked file parses off the main actor.
    private(set) var isLoading = false

    private static let logger = Logger(subsystem: "io.schwa.MetalSprocketsGaussianSplatsDemo", category: "loading")

    private(set) var splatCloud: GPUSplatCloud<SparkSplat>
    private let device: MTLDevice

    #if os(visionOS)
    var isImmersive = false
    var immersiveFrameTiming: FrameTimingStatistics?
    private(set) var renderState: SplatImmersiveRenderState
    #endif

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        let cloud = Self.loadSplatCloud(device: device, model: .tomatoes)
        self.splatCloud = cloud
        #if os(visionOS)
        // Demo-only: a missing Metal device is unrecoverable here.
        self.renderState = try! SplatImmersiveRenderState(splatCloud: cloud)
        #endif
    }

    private func reloadSplatCloud(model: SplatModel) {
        let cloud = Self.loadSplatCloud(device: device, model: model)
        splatCloud = cloud
        #if os(visionOS)
        renderState = try! SplatImmersiveRenderState(splatCloud: cloud)
        #endif
    }

    /// Loads a user-picked splat file from the file importer or drag and drop.
    ///
    /// The URL can be security-scoped. The parse runs off the main actor. Large
    /// files then do not freeze the UI or wedge the file dialog dismissal.
    func loadCustomSplat(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        isLoading = true
        defer {
            isLoading = false
        }
        Self.logger.info("Loading \(url.lastPathComponent, privacy: .public)…")
        let start = ContinuousClock.now
        do {
            let cloud = try await Self.readSplatCloudOffMain(device: device, url: url)
            Self.logger.info("Loaded \(cloud.count) splats in \((ContinuousClock.now - start).description, privacy: .public)")
            splatCloud = cloud
            customModelName = url.lastPathComponent
            selectedModel = nil
            #if os(visionOS)
            renderState = try SplatImmersiveRenderState(splatCloud: cloud)
            #endif
        } catch {
            Self.logger.error("Load failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            loadError = "Could not load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Generates a sphere-rainbow splat cloud of `count` splats off the main
    /// actor, then swaps it in.
    func generateSplats(count: Int) async {
        isLoading = true
        defer {
            isLoading = false
        }
        Self.logger.info("Generating \(count) splats…")
        let start = ContinuousClock.now
        do {
            let cloud = try await Self.generateSplatCloudOffMain(device: device, count: count)
            Self.logger.info("Generated \(count) splats in \((ContinuousClock.now - start).description, privacy: .public)")
            splatCloud = cloud
            customModelName = "Sphere \(SplatGenerator.label(for: count)) (generated)"
            selectedModel = nil
            #if os(visionOS)
            renderState = try SplatImmersiveRenderState(splatCloud: cloud)
            #endif
        } catch {
            Self.logger.error("Generation failed: \(error, privacy: .public)")
            loadError = "Could not generate splats: \(error.localizedDescription)"
        }
    }

    @concurrent
    nonisolated private static func generateSplatCloudOffMain(device: MTLDevice, count: Int) async throws -> GPUSplatCloud<SparkSplat> {
        let splats = await SplatGenerator.generate(count: count)
        return try GPUSplatCloud<SparkSplat>(device: device, splats: splats, mortonOrdered: true)
    }

    private static func loadSplatCloud(device: MTLDevice, model: SplatModel) -> GPUSplatCloud<SparkSplat> {
        let url = Bundle.main.url(forResource: model.resourceName, withExtension: model.resourceExtension)!
        return try! readSplatCloud(device: device, url: url)
    }

    /// Off-main wrapper for ``readSplatCloud(device:url:)`` so large files do
    /// not block the main actor. `@concurrent` keeps the call structured, so
    /// priority escalation and task-locals propagate, unlike Task.detached.
    @concurrent
    nonisolated private static func readSplatCloudOffMain(device: MTLDevice, url: URL) async throws -> GPUSplatCloud<SparkSplat> {
        try readSplatCloud(device: device, url: url)
    }

    /// Reads a splat file into a GPU cloud. Includes spherical harmonics when
    /// present, flattened to the coefficient-major layout the shaders expect.
    nonisolated private static func readSplatCloud(device: MTLDevice, url: URL) throws -> GPUSplatCloud<SparkSplat> {
        // SOG decodes on the GPU with a compute-kernel de-quantize. Every other
        // format streams through the CPU reader. Morton reorder (#89) applies to
        // the CPU paths. The SOG GPU path decodes straight into buffers.
        let result = try SplatLoader.read(device: device, url: url, mortonOrdered: true)
        return GPUSplatCloud(result)
    }
}
#endif
