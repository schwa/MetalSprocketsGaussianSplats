#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders

/// Compute pass that computes exclusive prefix sum of tile counters
/// Output: tileOffsets[i] = starting index for tile i in the compacted buffer
/// Also computes maxTileCount for heatmap normalization
public struct TilePrefixSumComputePass: Element {
    // MARK: - Properties

    var tileSplatResources: TileSplatResources

    @MSState
    var computeKernel: ComputeKernel

    // MARK: - Initialization

    public init(tileSplatResources: TileSplatResources) throws {
        self.tileSplatResources = tileSplatResources

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
            .namespaced("TilePrefixSum")
        self.computeKernel = try shaderLibrary.function(named: "tile_prefix_sum", type: ComputeKernel.self)
    }

    // MARK: - Element Body

    public var body: some Element {
        get throws {
            // Run prefix sum kernel - single thread
            try ComputePass(label: "Tile Prefix Sum") {
                try ComputePipeline(computeKernel: computeKernel) {
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: 1, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
                    )
                    .parameter("tileCounters", buffer: tileSplatResources.tileCounters.unsafeMTLBuffer)
                    .parameter("tileOffsets", buffer: tileSplatResources.tileOffsets.unsafeMTLBuffer)
                    .parameter("numTiles", value: UInt32(tileSplatResources.numTiles))
                    .parameter("maxTileCount", buffer: tileSplatResources.maxTileCount.unsafeMTLBuffer)
                }
            }
        }
    }
}

#endif
