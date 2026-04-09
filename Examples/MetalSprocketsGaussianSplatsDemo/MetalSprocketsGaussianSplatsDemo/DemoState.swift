#if !arch(x86_64)
import MetalSprocketsGaussianSplats
#if os(visionOS)
import MetalSprocketsUI
#endif
import Observation

@Observable
class DemoState {
    var renderer: SplatRenderer = .spark
    #if os(visionOS)
    var isImmersive = false
    var immersiveFrameTiming: FrameTimingStatistics?
    #endif
}
#endif
