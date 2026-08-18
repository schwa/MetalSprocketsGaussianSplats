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
    var renderer: SplatRenderer = .gpu
    /// The selected bundled model; nil while a user-loaded file is shown.
    var selectedModel: SplatModel? = .tomatoes {
        didSet {
            if let selectedModel, selectedModel != oldValue {
                customModelName = nil
                reloadSplatCloud(model: selectedModel)
            }
        }
    }
    /// Display name of a user-loaded splat file; nil when a bundled model is shown.
    private(set) var customModelName: String?
    var loadError: String?
    /// True while a user-picked file is being parsed off the main actor.
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

    /// Loads a user-picked splat file (file importer or drag & drop). The
    /// URL may be security-scoped. Parsing runs off the main actor so large
    /// files neither freeze the UI nor wedge the file dialog's dismissal.
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
    /// actor and swaps it in.
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

    /// Off-main wrapper for ``readSplatCloud(device:url:)`` so large files
    /// don't block the main actor. `@concurrent` keeps the call structured
    /// (priority escalation and task-locals propagate), unlike Task.detached.
    @concurrent
    nonisolated private static func readSplatCloudOffMain(device: MTLDevice, url: URL) async throws -> GPUSplatCloud<SparkSplat> {
        try readSplatCloud(device: device, url: url)
    }

    /// Reads a splat file into a GPU cloud, including spherical harmonics
    /// when present (flattened to the coefficient-major layout the shaders
    /// expect).
    nonisolated private static func readSplatCloud(device: MTLDevice, url: URL) throws -> GPUSplatCloud<SparkSplat> {
        // SOG: GPU decode path (concurrent WebP decode + compute-kernel
        // de-quantize straight into the SparkSplat buffer). Orders of
        // magnitude faster than the per-splat CPU reader for large files.
        if url.pathExtension.lowercased() == "sog" {
            let result = try SOGReaderGPU(device: device).read(url: url)
            let shCoefficients = result.shDegree > 0 ? result.shCoefficients : nil
            return GPUSplatCloud<SparkSplat>(splats: result.splats, shCoefficients: shCoefficients, shDegree: result.shDegree)
        }

        let reader = try SplatReader(url: url)
        let shDegree = reader.shDegree
        var splats: [SparkSplat] = []
        splats.reserveCapacity(reader.splatCount)
        var shCoefficients: [Float] = []
        try reader.read { _, extendedSplat in
            splats.append(SparkSplat(extendedSplat.genericSplat))
            if shDegree > 0, let sh = extendedSplat.sphericalHarmonics {
                for coefficient in sh {
                    shCoefficients.append(contentsOf: coefficient)
                }
            }
        }
        let floatsPerSplat = [0, 9, 24, 45][min(Int(shDegree), 3)]
        // Morton-reorder for group-culling coherence (#89); the SOG GPU
        // path above skips this since its splats decode straight into GPU
        // buffers.
        if floatsPerSplat > 0, shCoefficients.count == splats.count * floatsPerSplat {
            return try GPUSplatCloud<SparkSplat>(device: device, splats: splats, shCoefficients: shCoefficients, shDegree: shDegree, mortonOrdered: true)
        }
        return try GPUSplatCloud<SparkSplat>(device: device, splats: splats, mortonOrdered: true)
    }
}
#endif
