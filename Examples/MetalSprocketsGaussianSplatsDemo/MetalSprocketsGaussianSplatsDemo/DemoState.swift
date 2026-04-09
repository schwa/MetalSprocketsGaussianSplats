#if !arch(x86_64)
import MetalSprocketsGaussianSplats
import Observation

@Observable
class DemoState {
    var renderer: SplatRenderer = .spark
    #if os(visionOS)
    var isImmersive = false
    #endif
}
#endif
