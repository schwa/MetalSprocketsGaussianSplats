#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

public struct SparkSplatRenderPipeline<Splat: SortableSplatProtocol>: Element {
    var splatCloud: SplatCloud<Splat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>

    @MSState
    private var sortManager: AsyncSortManager<Splat>?

    public init(splatCloud: SplatCloud<Splat>, projectionMatrix: simd_float4x4, modelMatrix: simd_float4x4, cameraMatrix: simd_float4x4, drawableSize: SIMD2<Float>) throws {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
    }

    public var body: some Element {
        get throws {
            EmptyElement()
                .onChange(of: splatCloud, initial: true) { _, _ in
                    sortManager = try! AsyncSortManager(device: _MTLCreateSystemDefaultDevice(), splatCloud: splatCloud, capacity: splatCloud.count, logger: sparkLogger)
                    Task {
                        let channel = await sortManager!.sortedIndicesChannel()
                        for await sort in channel {
                            if sort.parameters.time < splatCloud.indexedDistances.parameters.time {
                                sparkLogger?.error("Out of order sort")
                                return
                            }

                            splatCloud.indexedDistances = sort
                        }
                    }
                    requestSort()
                }
                .onChange(of: cameraMatrix) {
                    requestSort()
                }
        }
    }

    func requestSort() {
        guard let sortManager else {
            fatalError("No sort manager")
        }
        let parameters = SortParameters(camera: cameraMatrix, model: modelMatrix)
        sortManager.requestSort(parameters)
    }
}

#endif
