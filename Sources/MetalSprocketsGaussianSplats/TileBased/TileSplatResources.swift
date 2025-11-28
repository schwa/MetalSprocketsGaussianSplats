#if os(iOS) || (os(macOS) && !arch(x86_64))
import Foundation
import Metal
import MetalSprocketsGaussianSplatShaders
import simd

/// Resources for tile-based splat rendering
/// Manages GPU buffers for tile binning, sorting, and rendering
public final class TileSplatResources {
    // MARK: - Configuration

    public static let tileSize = UInt32(TILE_SIZE)

    /// Maximum total splat-tile intersections (splats * average tiles per splat)
    /// Conservative estimate: each splat overlaps ~8 tiles on average
    public static let maxTotalSplatTileIntersections = 16 * 1024 * 1024  // 16M entries = 128MB

    // MARK: - Properties

    /// Device used to create buffers
    public let device: MTLDevice

    /// Size of tile grid (in tiles)
    public private(set) var tileGridSize: SIMD2<UInt32>

    /// Total number of tiles
    public var numTiles: Int {
        Int(tileGridSize.x) * Int(tileGridSize.y)
    }

    /// Buffer containing TileSplatIndex entries for all tiles (compacted)
    /// Layout: [tile_0_indices...][tile_1_indices...]...[tile_N_indices...]
    /// Each tile's range is defined by tileOffsets[tile] to tileOffsets[tile+1]
    /// Two buffers for ping-pong radix sorting
    public private(set) var tileSplatIndicesA: TypedMTLBuffer<TileSplatIndex>
    public private(set) var tileSplatIndicesB: TypedMTLBuffer<TileSplatIndex>

    /// Atomic counter buffer - one uint per tile tracking actual splat count
    public private(set) var tileCounters: TypedMTLBuffer<UInt32>

    /// Prefix sum of tile counts - tileOffsets[i] is starting index for tile i
    /// tileOffsets[numTiles] contains total count
    public private(set) var tileOffsets: TypedMTLBuffer<UInt32>

    /// Drawable size this resource was created for
    public private(set) var drawableSize: SIMD2<Float>

    // MARK: - Initialization

    public init(device: MTLDevice, drawableSize: SIMD2<Float>) throws {
        self.device = device
        self.drawableSize = drawableSize

        // Compute tile grid dimensions
        let gridWidth = (UInt32(drawableSize.x) + Self.tileSize - 1) / Self.tileSize
        let gridHeight = (UInt32(drawableSize.y) + Self.tileSize - 1) / Self.tileSize
        self.tileGridSize = SIMD2(gridWidth, gridHeight)

        let totalTiles = Int(gridWidth) * Int(gridHeight)

        // Allocate two compacted tile splat index buffers for ping-pong sorting
        self.tileSplatIndicesA = try device.makeTypedBuffer(element: TileSplatIndex.self, capacity: Self.maxTotalSplatTileIntersections, options: .storageModePrivate).labeled("TileSplatIndicesA")
        self.tileSplatIndicesA.count = Self.maxTotalSplatTileIntersections

        self.tileSplatIndicesB = try device.makeTypedBuffer(element: TileSplatIndex.self, capacity: Self.maxTotalSplatTileIntersections, options: .storageModePrivate).labeled("TileSplatIndicesB")
        self.tileSplatIndicesB.count = Self.maxTotalSplatTileIntersections

        // Allocate tile counter buffer
        self.tileCounters = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModePrivate).labeled("TileCounters")
        self.tileCounters.count = totalTiles

        // Allocate tile offsets buffer (numTiles + 1 for total count)
        self.tileOffsets = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles + 1, options: .storageModePrivate).labeled("TileOffsets")
        self.tileOffsets.count = totalTiles + 1
    }

    // MARK: - Resize

    /// Check if resources need to be reallocated for new drawable size
    public func needsResize(for newDrawableSize: SIMD2<Float>) -> Bool {
        let newGridWidth = (UInt32(newDrawableSize.x) + Self.tileSize - 1) / Self.tileSize
        let newGridHeight = (UInt32(newDrawableSize.y) + Self.tileSize - 1) / Self.tileSize
        return newGridWidth != tileGridSize.x || newGridHeight != tileGridSize.y
    }

    /// Resize buffers for new drawable size
    public func resize(for newDrawableSize: SIMD2<Float>) throws {
        guard needsResize(for: newDrawableSize) else {
            return
        }

        self.drawableSize = newDrawableSize

        let gridWidth = (UInt32(newDrawableSize.x) + Self.tileSize - 1) / Self.tileSize
        let gridHeight = (UInt32(newDrawableSize.y) + Self.tileSize - 1) / Self.tileSize
        self.tileGridSize = SIMD2(gridWidth, gridHeight)

        let totalTiles = Int(gridWidth) * Int(gridHeight)

        // tileSplatIndices doesn't need resize - it's sized for max total intersections

        // Reallocate tile counter buffer
        self.tileCounters = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModePrivate).labeled("TileCounters")
        self.tileCounters.count = totalTiles

        // Reallocate tile offsets buffer
        self.tileOffsets = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles + 1, options: .storageModePrivate).labeled("TileOffsets")
        self.tileOffsets.count = totalTiles + 1
    }

    // MARK: - Uniforms

    /// Create uniforms struct for shader use
    public func makeUniforms(
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

    /// Total GPU memory used by tile resources (in bytes)
    public var totalMemoryUsage: Int {
        let indexBufferASize = tileSplatIndicesA.unsafeMTLBuffer.length
        let indexBufferBSize = tileSplatIndicesB.unsafeMTLBuffer.length
        let counterBufferSize = tileCounters.unsafeMTLBuffer.length
        let offsetsBufferSize = tileOffsets.unsafeMTLBuffer.length
        return indexBufferASize + indexBufferBSize + counterBufferSize + offsetsBufferSize
    }

    /// Human-readable memory usage string
    public var memoryUsageDescription: String {
        let mb = Double(totalMemoryUsage) / (1_024 * 1_024)
        return String(format: "%.1f MB (%d tiles, max %d total intersections)", mb, numTiles, Self.maxTotalSplatTileIntersections)
    }
}

#endif
