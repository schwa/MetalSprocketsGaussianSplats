#if !arch(x86_64)
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Splats
#if os(visionOS)
import MetalSprocketsUI
#endif
import Observation

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
    var selectedModel: SplatModel = .butterfly {
        didSet {
            if selectedModel != oldValue {
                customModelName = nil
                reloadSplatCloud()
            }
        }
    }
    /// Display name of a user-loaded splat file; nil when a bundled model is shown.
    private(set) var customModelName: String?
    var loadError: String?

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

    private func reloadSplatCloud() {
        let cloud = Self.loadSplatCloud(device: device, model: selectedModel)
        splatCloud = cloud
        #if os(visionOS)
        renderState = SplatImmersiveRenderState(splatCloud: cloud)
        #endif
    }

    /// Loads a user-picked splat file (e.g. from a file importer). The URL
    /// may be security-scoped.
    func loadCustomSplat(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let cloud = try Self.readSplatCloud(device: device, url: url)
            splatCloud = cloud
            customModelName = url.lastPathComponent
            #if os(visionOS)
            renderState = SplatImmersiveRenderState(splatCloud: cloud)
            #endif
        } catch {
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
    private static func readSplatCloud(device: MTLDevice, url: URL) throws -> GPUSplatCloud<SparkSplat> {
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
