#if !arch(x86_64)

import Metal
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import Splats

/// GPU buffers for the GPU splat sorter (cull + compact + 8-bit LSD radix).
///
/// Keeps `slotCount` independent sets of scratch + output buffers so several
/// frames can be in flight without racing. The pipeline advances the slot each
/// frame; the caller must gate in-flight frames to at most `slotCount`.
public final class GPUSortResources {
    /// One frame's worth of scratch and the output the renderer reads.
    struct Slot {
        var recordsA: MTLBuffer
        var recordsB: MTLBuffer
        var hist: MTLBuffer
        var offset: MTLBuffer
        var total: MTLBuffer
        var digitBase: MTLBuffer
        var output: TypedMTLBuffer<IndexedDistance>
        /// `MTLDrawPrimitivesIndirectArguments`. `instanceCount` is the survivor
        /// count written by the block scan, read by every element-bound sort
        /// kernel, and consumed by the indirect draw.
        var drawArgs: MTLBuffer
        /// Per-block survivor counts (phase 1) and their exclusive prefix sum
        /// (phase 2), one entry per COMPACT_BLOCK-element block.
        var blockCounts: MTLBuffer
        var blockBase: MTLBuffer
    }

    /// Elements per compaction block. Must match COMPACT_BLOCK in SplatGPUSort.metal.
    static let compactBlock = 256
    /// Elements per radix tile. Must match the histogram/scatter kernel tiling.
    static let elementsPerTile = 1_024

    public let device: MTLDevice
    public let slotCount: Int
    public private(set) var capacity: Int
    private(set) var slots: [Slot]
    private var slotIndex = 0

    public init(device: MTLDevice, capacity: Int, slotCount: Int = 3) throws {
        self.device = device
        self.slotCount = slotCount
        self.capacity = max(capacity, 1)
        slots = []
        slots = try (0..<slotCount).map { try Self.makeSlot(device: device, capacity: self.capacity, index: $0) }
    }

    /// Grow all slots to hold at least `newCapacity` splats. No-op when smaller.
    public func ensure(capacity newCapacity: Int) throws {
        guard newCapacity > capacity else { return }
        capacity = newCapacity
        slots = try (0..<slotCount).map { try Self.makeSlot(device: device, capacity: newCapacity, index: $0) }
    }

    /// Build ``SplatIndices`` viewing a slot's output buffer + indirect draw
    /// args. Valid until the same slot is reused `slotCount` frames later.
    func makeIndices(slot slotIndex: Int, count: Int, parameters: SortParameters) -> SplatIndices {
        var slot = slots[slotIndex]
        slot.output.count = count
        slots[slotIndex] = slot
        return SplatIndices(parameters: parameters, indices: slot.output, indirectDrawArgs: slot.drawArgs)
    }

    /// Advance to the next slot and return its index. Call once per frame.
    func advance() -> Int {
        slotIndex = (slotIndex + 1) % slotCount
        return slotIndex
    }

    private static func makeSlot(device: MTLDevice, capacity: Int, index: Int) throws -> Slot {
        let maxTiles = (capacity + elementsPerTile - 1) / elementsPerTile
        let maxBlocks = (capacity + compactBlock - 1) / compactBlock
        // Scratch + output buffers are GPU-only (filled and consumed entirely on
        // the GPU), so they live in private storage to save bandwidth/memory.
        // Exception: `drawArgs` is read back via `.contents()` on the CPU for the
        // survivor-count stat, so it must stay shared.
        func buffer(_ length: Int, _ label: String, _ storage: MTLResourceOptions = .storageModePrivate) throws -> MTLBuffer {
            let buffer = try device.makeBuffer(length: max(length, 4), options: storage).orThrow(.resourceCreationFailure("Failed to allocate \(label)"))
            buffer.label = "GPUSort-\(label)-slot\(index)"
            return buffer
        }
        let recordStride = MemoryLayout<SIMD2<UInt32>>.stride
        let outputBuffer = try buffer(capacity * MemoryLayout<IndexedDistance>.stride, "output")
        return Slot(
            recordsA: try buffer(capacity * recordStride, "recordsA"),
            recordsB: try buffer(capacity * recordStride, "recordsB"),
            hist: try buffer(256 * maxTiles * 4, "hist"),
            offset: try buffer(256 * maxTiles * 4, "offset"),
            total: try buffer(256 * 4, "total"),
            digitBase: try buffer(256 * 4, "digitBase"),
            output: TypedMTLBuffer<IndexedDistance>(buffer: outputBuffer, count: 0),
            drawArgs: try buffer(4 * 4, "drawArgs", .storageModeShared),
            blockCounts: try buffer(maxBlocks * 4, "blockCounts"),
            blockBase: try buffer(maxBlocks * 4, "blockBase")
        )
    }
}

#endif
