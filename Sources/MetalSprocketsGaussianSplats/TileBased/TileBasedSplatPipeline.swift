#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport

/// Complete tile-based splat rendering pipeline
/// Combines binning, sorting, and rendering passes
/// Note: This is an Element-based pipeline for use within RenderPass contexts.
/// For SwiftUI integration, use TileBasedSplatView instead.
public struct TileBasedSplatPipeline: Element {
    // MARK: - Properties

    var splatCloud: SplatCloud<SparkSplat>
    var projectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var cameraMatrix: simd_float4x4
    var drawableSize: SIMD2<Float>
    var tileSplatResources: TileSplatResources
    var debugTileBorders: Bool
    var showHeatMap: Bool

    // MARK: - Initialization

    public init(
        splatCloud: SplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        drawableSize: SIMD2<Float>,
        tileSplatResources: TileSplatResources,
        debugTileBorders: Bool = false,
        showHeatMap: Bool = false
    ) {
        self.splatCloud = splatCloud
        self.projectionMatrix = projectionMatrix
        self.modelMatrix = modelMatrix
        self.cameraMatrix = cameraMatrix
        self.drawableSize = drawableSize
        self.tileSplatResources = tileSplatResources
        self.debugTileBorders = debugTileBorders
        self.showHeatMap = showHeatMap
    }

    // MARK: - Element Body

    public var body: some Element {
        get throws {
            // Pass 1a: Count splats per tile
            try TileBinningCountPass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                tileSplatResources: tileSplatResources
            )

            // Pass 1b: Compute prefix sum of tile counts
            try TilePrefixSumComputePass(
                tileSplatResources: tileSplatResources
            )

            // Pass 1c: Write splats to compacted buffer using offsets
            try TileBinningWritePass(
                splatCloud: splatCloud,
                projectionMatrix: projectionMatrix,
                modelMatrix: modelMatrix,
                cameraMatrix: cameraMatrix,
                drawableSize: drawableSize,
                tileSplatResources: tileSplatResources
            )

            // Pass 2: Per-Tile Sorting
            // Sorts each tile's splat list by depth (front-to-back)
            try TileSortingComputePass(
                tileSplatResources: tileSplatResources
            )

            // Pass 3: Tile Rendering (fragment shader with imageblock)
            // Renders each pixel using sorted splat lists with early alpha termination
            try RenderPass {
                try TileSplatRenderPass(
                    splatCloud: splatCloud,
                    tileSplatResources: tileSplatResources,
                    projectionMatrix: projectionMatrix,
                    modelMatrix: modelMatrix,
                    cameraMatrix: cameraMatrix,
                    drawableSize: drawableSize,
                    debugTileBorders: debugTileBorders
                )
            }
            .renderPassDescriptorModifier { descriptor in
                // Configure for Metal tile shading with imageblock
                descriptor.tileWidth = Int(TILE_SIZE)
                descriptor.tileHeight = Int(TILE_SIZE)
                // TileSplatImageblock contains half4 = 4 * 2 bytes = 8 bytes, aligned to 16
                descriptor.imageblockSampleLength = 16
            }

            // Optional: Heatmap overlay showing splat density per tile
            if showHeatMap {
                try RenderPass {
                    try TileHeatMapRenderPass(tileSplatResources: tileSplatResources)
                }
            }
        }
    }
}

#endif
