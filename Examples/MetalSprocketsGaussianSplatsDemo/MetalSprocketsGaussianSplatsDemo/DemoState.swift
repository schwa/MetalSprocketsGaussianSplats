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
        case .butterfly: "butterfly-wings-closed"
        case .helmet: "Helmet"
        }
    }

    var resourceExtension: String {
        switch self {
        case .butterfly: "spz"
        case .helmet: "sog"
        }
    }
}

@Observable
class DemoState {
    var renderer: SplatRenderer = .spark
    var selectedModel: SplatModel = .butterfly {
        didSet {
            if selectedModel != oldValue {
                reloadSplatCloud()
            }
        }
    }

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

    private static func loadSplatCloud(device: MTLDevice, model: SplatModel) -> GPUSplatCloud<SparkSplat> {
        let url = Bundle.main.url(forResource: model.resourceName, withExtension: model.resourceExtension)!
        let reader = try! SplatReader(url: url)
        var splats: [SparkSplat] = []
        splats.reserveCapacity(reader.splatCount)
        try! reader.read { _, extendedSplat in
            splats.append(SparkSplat(extendedSplat.genericSplat))
        }
        return try! GPUSplatCloud<SparkSplat>(device: device, splats: splats)
    }
}
#endif
