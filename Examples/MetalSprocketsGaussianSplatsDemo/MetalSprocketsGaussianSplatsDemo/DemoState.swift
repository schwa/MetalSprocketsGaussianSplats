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
    case butterfly = "Butterfly"
    case helmet = "Helmet"

    var id: String { rawValue }

    var resourceName: String {
        switch self {
        case .butterfly:
            "butterfly-wings-closed"
        case .helmet:
            "Helmet"
        }
    }

    var resourceExtension: String {
        switch self {
        case .butterfly:
            "spz"
        case .helmet:
            "sog"
        }
    }
}

@Observable
class DemoState {
    var renderer: SplatRenderer = .spark
    /// The selected bundled model; nil while a user-loaded file is shown.
    var selectedModel: SplatModel? = .butterfly {
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
        let cloud = Self.loadSplatCloud(device: device, model: .butterfly)
        self.splatCloud = cloud
        #if os(visionOS)
        self.renderState = SplatImmersiveRenderState(splatCloud: cloud)
        #endif
    }

    private func reloadSplatCloud(model: SplatModel) {
        let cloud = Self.loadSplatCloud(device: device, model: model)
        splatCloud = cloud
        #if os(visionOS)
        renderState = SplatImmersiveRenderState(splatCloud: cloud)
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
            let device = self.device
            let cloud = try await Task.detached(priority: .userInitiated) {
                try Self.readSplatCloud(device: device, url: url)
            }.value
            Self.logger.info("Loaded \(cloud.count) splats in \((ContinuousClock.now - start).description, privacy: .public)")
            splatCloud = cloud
            customModelName = url.lastPathComponent
            selectedModel = nil
            #if os(visionOS)
            renderState = SplatImmersiveRenderState(splatCloud: cloud)
            #endif
        } catch {
            Self.logger.error("Load failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            loadError = "Could not load \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private static func loadSplatCloud(device: MTLDevice, model: SplatModel) -> GPUSplatCloud<SparkSplat> {
        let url = Bundle.main.url(forResource: model.resourceName, withExtension: model.resourceExtension)!
        return try! readSplatCloud(device: device, url: url)
    }

    /// Reads a splat file into a GPU cloud, including spherical harmonics
    /// when present (flattened to the coefficient-major layout the shaders
    /// expect).
    nonisolated private static func readSplatCloud(device: MTLDevice, url: URL) throws -> GPUSplatCloud<SparkSplat> {
        // SOG: GPU decode path (concurrent WebP decode + compute-kernel
        // de-quantize straight into the SparkSplat buffer). Orders of
        // magnitude faster than the per-splat CPU reader for large files.
        if url.pathExtension.lowercased() == "sog" {
            let result = try SOGReaderGPU(device: device).load(url: url)
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
        if floatsPerSplat > 0, shCoefficients.count == splats.count * floatsPerSplat {
            return try GPUSplatCloud<SparkSplat>(device: device, splats: splats, shCoefficients: shCoefficients, shDegree: shDegree)
        }
        return try GPUSplatCloud<SparkSplat>(device: device, splats: splats)
    }
}
#endif
