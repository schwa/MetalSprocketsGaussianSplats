#if !arch(x86_64)
import GeometryLite3D
import Interaction3D
import Metal
import MetalSprocketsGaussianSplats
import MetalSprocketsGaussianSplatShaders
import Splats
import SwiftUI

func loadSplatCloud() -> GPUSplatCloud<SparkSplat> {
    let device = MTLCreateSystemDefaultDevice()!
    let url = Bundle.main.url(forResource: "butterfly-wings-closed", withExtension: "spz")!
    let reader = try! SplatReader(url: url)
    var splats: [SparkSplat] = []
    splats.reserveCapacity(reader.splatCount)
    try! reader.read { _, extendedSplat in
        splats.append(SparkSplat(extendedSplat.genericSplat))
    }
    return try! GPUSplatCloud<SparkSplat>(device: device, splats: splats)
}

#if os(visionOS)
struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isImmersive = false
    @State private var cameraMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, 3))

    let splatCloud: GPUSplatCloud<SparkSplat>

    init() {
        self.splatCloud = loadSplatCloud()
    }

    var body: some View {
        VStack {
            SplatView(
                splatCloud: splatCloud,
                cameraMatrix: cameraMatrix
            )
            .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())

            Button(isImmersive ? "Exit Immersive" : "View in Immersive Space") {
                Task {
                    if isImmersive {
                        await dismissImmersiveSpace()
                        isImmersive = false
                    } else {
                        let result = await openImmersiveSpace(id: "SplatImmersive")
                        if case .opened = result {
                            isImmersive = true
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}
#else
struct ContentView: View {
    @State private var cameraMatrix = simd_float4x4(translation: SIMD3<Float>(0, 0, 3))

    let splatCloud: GPUSplatCloud<SparkSplat>

    init() {
        self.splatCloud = loadSplatCloud()
    }

    var body: some View {
        SplatView(
            splatCloud: splatCloud,
            cameraMatrix: cameraMatrix
        )
        .interactiveCamera(cameraMatrix: $cameraMatrix, mode: .turntable())
    }
}
#endif

#else
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Gaussian splat rendering requires Apple Silicon.")
    }
}
#endif
