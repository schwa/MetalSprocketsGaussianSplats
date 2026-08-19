#if !arch(x86_64)
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders

/// Compute pass that computes the exclusive prefix sum of the tile counters.
///
/// Output: `tileOffsets[i]` is the start index for tile i in the compacted
/// buffer. The pass also computes `maxTileCount` for heatmap normalization.
///
/// - Important: This type is part of the **experimental** tile-based renderer.
///   It can change or move in a future version.
struct TilePrefixSumComputePass: Element {
    // MARK: - Properties

    var tileSplatResources: TileSplatResources

    @MSState
    var computeKernel: ComputeKernel

    // MARK: - Initialization

    init(tileSplatResources: TileSplatResources) throws {
        self.tileSplatResources = tileSplatResources

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
            .namespaced("TilePrefixSum")
        self.computeKernel = try shaderLibrary.function(named: "tile_prefix_sum", type: ComputeKernel.self)
    }

    // MARK: - Element Body

    var body: some Element {
        get throws {
            // Run the prefix sum kernel with a single thread.
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
