#if !arch(x86_64)
import Foundation
import Metal
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

/// Resources for tile-based splat rendering.
///
/// This type manages the GPU buffers for tile binning, sorting, and rendering.
///
/// - Important: This type is part of the **experimental** tile-based renderer.
///   It can change or move in a future version.
final class TileSplatResources {
    // MARK: - Configuration

    static let tileSize = UInt32(TILE_SIZE)

    /// Maximum total splat-tile intersections (splats times the average tiles
    /// per splat). Each splat overlaps about 8 tiles on average.
    static let maxTotalSplatTileIntersections = 16 * 1_024 * 1_024  // 16M entries = 128MB

    // MARK: - Properties

    /// Device that creates the buffers.
    let device: MTLDevice

    /// Size of the tile grid, in tiles.
    private(set) var tileGridSize: SIMD2<UInt32>

    /// Total number of tiles.
    var numTiles: Int {
        Int(tileGridSize.x) * Int(tileGridSize.y)
    }

    /// TileSplatIndex entries for all tiles (compacted).
    /// Layout: [tile_0_indices...][tile_1_indices...]...[tile_N_indices...].
    /// Each tile's range runs from tileOffsets[tile] to tileOffsets[tile+1].
    /// Two buffers ping-pong for the radix sort.
    private(set) var tileSplatIndicesA: TypedMTLBuffer<TileSplatIndex>
    private(set) var tileSplatIndicesB: TypedMTLBuffer<TileSplatIndex>

    /// Atomic counter buffer. One uint per tile tracks the actual splat count.
    private(set) var tileCounters: TypedMTLBuffer<UInt32>

    /// Prefix sum of the tile counts. tileOffsets[i] is the start index for
    /// tile i. tileOffsets[numTiles] holds the total count.
    private(set) var tileOffsets: TypedMTLBuffer<UInt32>

    /// Maximum splat count across all tiles, for heatmap normalization.
    /// The prefix sum kernel writes it.
    private(set) var maxTileCount: TypedMTLBuffer<UInt32>

    /// Per-splat 2D projection data (screen center, conic, linear color).
    /// The binning write kernel writes it and the render pass reads it (#58).
    /// It grows on demand through ``ensureProjectedSplatCapacity(_:)``.
    private(set) var projectedSplats: TypedMTLBuffer<TileProjectedSplat>

    /// Shared-mode buffer that reads the tile counts back to the CPU for stats.
    private(set) var tileCountersReadback: TypedMTLBuffer<UInt32>

    /// Drawable size this resource was created for.
    private(set) var drawableSize: SIMD2<Float>

    // MARK: - Initialization

    init(device: MTLDevice, drawableSize: SIMD2<Float>) throws {
        self.device = device
        self.drawableSize = drawableSize

        let gridWidth = (UInt32(drawableSize.x) + Self.tileSize - 1) / Self.tileSize
        let gridHeight = (UInt32(drawableSize.y) + Self.tileSize - 1) / Self.tileSize
        self.tileGridSize = SIMD2(gridWidth, gridHeight)

        let totalTiles = Int(gridWidth) * Int(gridHeight)

        // Two compacted index buffers ping-pong for the sort.
        self.tileSplatIndicesA = try device.makeTypedBuffer(element: TileSplatIndex.self, capacity: Self.maxTotalSplatTileIntersections, options: .storageModePrivate).labeled("TileSplatIndicesA")
        self.tileSplatIndicesA.count = Self.maxTotalSplatTileIntersections

        self.tileSplatIndicesB = try device.makeTypedBuffer(element: TileSplatIndex.self, capacity: Self.maxTotalSplatTileIntersections, options: .storageModePrivate).labeled("TileSplatIndicesB")
        self.tileSplatIndicesB.count = Self.maxTotalSplatTileIntersections

        self.tileCounters = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModePrivate).labeled("TileCounters")
        self.tileCounters.count = totalTiles

        // numTiles + 1: the last entry holds the total count.
        self.tileOffsets = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles + 1, options: .storageModePrivate).labeled("TileOffsets")
        self.tileOffsets.count = totalTiles + 1

        // Single uint for heatmap normalization.
        self.maxTileCount = try device.makeTypedBuffer(element: UInt32.self, capacity: 1, options: .storageModePrivate).labeled("MaxTileCount")
        self.maxTileCount.count = 1

        self.tileCountersReadback = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModeShared).labeled("TileCountersReadback")
        self.tileCountersReadback.count = totalTiles

        self.projectedSplats = try device.makeTypedBuffer(element: TileProjectedSplat.self, capacity: 1, options: .storageModePrivate).labeled("TileProjectedSplats")
        self.projectedSplats.count = 1
    }

    /// Grows the projected-splat buffer to hold at least `splatCount` entries.
    func ensureProjectedSplatCapacity(_ splatCount: Int) throws {
        let required = max(splatCount, 1)
        guard projectedSplats.capacity < required else {
            return
        }
        projectedSplats = try device.makeTypedBuffer(element: TileProjectedSplat.self, capacity: required, options: .storageModePrivate).labeled("TileProjectedSplats")
        projectedSplats.count = required
    }

    // MARK: - Resize

    /// Returns true if the resources need reallocation for a new drawable size.
    func needsResize(for newDrawableSize: SIMD2<Float>) -> Bool {
        let newGridWidth = (UInt32(newDrawableSize.x) + Self.tileSize - 1) / Self.tileSize
        let newGridHeight = (UInt32(newDrawableSize.y) + Self.tileSize - 1) / Self.tileSize
        return newGridWidth != tileGridSize.x || newGridHeight != tileGridSize.y
    }

    /// Resizes the buffers for a new drawable size.
    func resize(for newDrawableSize: SIMD2<Float>) throws {
        guard needsResize(for: newDrawableSize) else {
            return
        }

        self.drawableSize = newDrawableSize

        let gridWidth = (UInt32(newDrawableSize.x) + Self.tileSize - 1) / Self.tileSize
        let gridHeight = (UInt32(newDrawableSize.y) + Self.tileSize - 1) / Self.tileSize
        self.tileGridSize = SIMD2(gridWidth, gridHeight)

        let totalTiles = Int(gridWidth) * Int(gridHeight)

        // tileSplatIndices needs no resize; it is sized for the max total intersections.

        self.tileCounters = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModePrivate).labeled("TileCounters")
        self.tileCounters.count = totalTiles

        self.tileOffsets = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles + 1, options: .storageModePrivate).labeled("TileOffsets")
        self.tileOffsets.count = totalTiles + 1

        self.tileCountersReadback = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModeShared).labeled("TileCountersReadback")
        self.tileCountersReadback.count = totalTiles
    }

    // MARK: - Uniforms

    /// Creates the uniforms struct for shader use.
    func makeUniforms(
        modelMatrix: simd_float4x4,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        scale: Float = 2.0
    ) -> TileRenderUniforms {
        TileRenderUniforms(
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            drawableSize: drawableSize,
            tileGridSize: tileGridSize,
            scale: scale
        )
    }

    // MARK: - Memory Stats

    /// Total GPU memory that the tile resources use, in bytes.
    var totalMemoryUsage: Int {
        let indexBufferASize = tileSplatIndicesA.unsafeMTLBuffer.length
        let indexBufferBSize = tileSplatIndicesB.unsafeMTLBuffer.length
        let counterBufferSize = tileCounters.unsafeMTLBuffer.length
        let offsetsBufferSize = tileOffsets.unsafeMTLBuffer.length
        let maxTileCountSize = maxTileCount.unsafeMTLBuffer.length
        let readbackBufferSize = tileCountersReadback.unsafeMTLBuffer.length
        let projectedSplatsSize = projectedSplats.unsafeMTLBuffer.length
        return indexBufferASize + indexBufferBSize + counterBufferSize + offsetsBufferSize + maxTileCountSize + readbackBufferSize + projectedSplatsSize
    }

    /// Human-readable memory usage string.
    var memoryUsageDescription: String {
        let mb = Double(totalMemoryUsage) / (1_024 * 1_024)
        return "\(mb.formatted(.number.precision(.fractionLength(1)))) MB (\(numTiles) tiles, max \(Self.maxTotalSplatTileIntersections) total intersections)"
    }

    // MARK: - Stats Readback

    /// Reads the tile counts from the readback buffer. Call it after the GPU
    /// work completes.
    func readTileCounts() -> [UInt32] {
        Array(tileCountersReadback)
    }
}

#endif
