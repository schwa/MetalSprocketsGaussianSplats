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
    public static let maxSplatsPerTile = UInt32(MAX_SPLATS_PER_TILE)

    // MARK: - Properties

    /// Device used to create buffers
    public let device: MTLDevice

    /// Size of tile grid (in tiles)
    public private(set) var tileGridSize: SIMD2<UInt32>

    /// Total number of tiles
    public var numTiles: Int {
        Int(tileGridSize.x) * Int(tileGridSize.y)
    }

    /// Buffer containing TileSplatIndex entries for all tiles
    /// Layout: [tile_0_indices][tile_1_indices]...[tile_N_indices]
    /// Each tile has MAX_SPLATS_PER_TILE entries
    public private(set) var tileSplatIndices: TypedMTLBuffer<TileSplatIndex>

    /// Atomic counter buffer - one uint per tile tracking actual splat count
    public private(set) var tileCounters: TypedMTLBuffer<UInt32>

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
        let indexBufferCapacity = totalTiles * Int(Self.maxSplatsPerTile)

        // Allocate tile splat index buffer
        self.tileSplatIndices = try device.makeTypedBuffer(element: TileSplatIndex.self, capacity: indexBufferCapacity, options: .storageModePrivate).labeled("TileSplatIndices")
        self.tileSplatIndices.count = indexBufferCapacity

        // Allocate tile counter buffer
        self.tileCounters = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModePrivate).labeled("TileCounters")
        self.tileCounters.count = totalTiles
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
        let indexBufferCapacity = totalTiles * Int(Self.maxSplatsPerTile)

        // Reallocate buffers
        self.tileSplatIndices = try device.makeTypedBuffer(element: TileSplatIndex.self, capacity: indexBufferCapacity, options: .storageModePrivate).labeled("TileSplatIndices")
        self.tileSplatIndices.count = indexBufferCapacity

        self.tileCounters = try device.makeTypedBuffer(element: UInt32.self, capacity: totalTiles, options: .storageModePrivate).labeled("TileCounters")
        self.tileCounters.count = totalTiles
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
            maxSplatsPerTile: Self.maxSplatsPerTile,
            scale: scale
        )
    }

    // MARK: - Memory Stats

    /// Total GPU memory used by tile resources (in bytes)
    public var totalMemoryUsage: Int {
        let indexBufferSize = tileSplatIndices.unsafeMTLBuffer.length
        let counterBufferSize = tileCounters.unsafeMTLBuffer.length
        return indexBufferSize + counterBufferSize
    }

    /// Human-readable memory usage string
    public var memoryUsageDescription: String {
        let mb = Double(totalMemoryUsage) / (1_024 * 1_024)
        return String(format: "%.1f MB (%d tiles, %d splats/tile)", mb, numTiles, Self.maxSplatsPerTile)
    }
}

#endif
