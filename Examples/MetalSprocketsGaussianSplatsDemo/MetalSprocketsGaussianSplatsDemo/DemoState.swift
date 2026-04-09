#if !arch(x86_64)
import MetalSprocketsGaussianSplats
import Observation

@Observable
class DemoState {
    var renderer: SplatRenderer = .spark
}
#endif
