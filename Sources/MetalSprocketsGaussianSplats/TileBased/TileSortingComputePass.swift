#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

/// Compute pass that sorts each tile's splat list by depth (front-to-back)
public struct TileSortingComputePass: Element {
    // MARK: - Properties

    var tileSplatResources: TileSplatResources

    @MSState
    var sortKernel: ComputeKernel

    // MARK: - Initialization

    public init(tileSplatResources: TileSplatResources) throws {
        self.tileSplatResources = tileSplatResources

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
            .namespaced("TileSplatSort")
        self.sortKernel = try shaderLibrary.function(named: "tile_sort", type: ComputeKernel.self)
    }

    // MARK: - Element Body

    public var body: some Element {
        get throws {
            let numTiles = tileSplatResources.numTiles

            try ComputePass(label: "Tile Sort") {
                try ComputePipeline(computeKernel: sortKernel) {
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: numTiles, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
                    )
                    .parameter("tileSplatIndicesA", buffer: tileSplatResources.tileSplatIndicesA.unsafeMTLBuffer)
                    .parameter("tileSplatIndicesB", buffer: tileSplatResources.tileSplatIndicesB.unsafeMTLBuffer)
                    .parameter("tileOffsets", buffer: tileSplatResources.tileOffsets.unsafeMTLBuffer)
                    .parameter("numTiles", value: UInt32(numTiles))
                }
            }
        }
    }
}

#endif
