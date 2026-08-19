#if !arch(x86_64)

import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import Splats

/// Compute pass encoding the full GPU splat sort for one cloud into one slot of
/// a ``GPUSortResources``: frustum cull + stable compaction, then a two-pass
/// 8-bit LSD radix over the 16-bit half depth key, then decode into
/// `IndexedDistance` records the render vertex shader reads.
///
/// Culled splats are dropped before the radix so the sort processes only
/// survivors; the survivor count lands in the slot's indirect draw args
/// (`instanceCount`) for the render pass to draw with.
public struct GPUSplatSortComputePass: Element {
    var splatCloud: GPUSplatCloud<SparkSplat>
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var cullEnabled: Bool
    var guardBand: Float
    var reversed: Bool
    var resources: GPUSortResources
    var slotIndex: Int

    @MSState var cullMark: ComputeKernel
    @MSState var compactScanBlocks: ComputeKernel
    @MSState var compactScatter: ComputeKernel
    @MSState var histogram: ComputeKernel
    @MSState var scanOffsets: ComputeKernel
    @MSState var scanDigitBase: ComputeKernel
    @MSState var scatter: ComputeKernel        // decode_output = false
    @MSState var scatterDecode: ComputeKernel  // decode_output = true (final pass)

    /// Convenience initializer for mono (single-view) sorting.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        cameraMatrix: simd_float4x4,
        cullEnabled: Bool = true,
        guardBand: Float = 0.2,
        reversed: Bool = false,
        resources: GPUSortResources,
        slotIndex: Int
    ) throws {
        try self.init(
            splatCloud: splatCloud,
            projectionMatrices: [projectionMatrix],
            modelMatrix: modelMatrix,
            cameraMatrices: [cameraMatrix],
            cullEnabled: cullEnabled,
            guardBand: guardBand,
            reversed: reversed,
            resources: resources,
            slotIndex: slotIndex
        )
    }

    /// Full initializer supporting stereo. With two views the cull keeps any
    /// splat visible to either view; the sort key is the first view's depth.
    public init(
        splatCloud: GPUSplatCloud<SparkSplat>,
        projectionMatrices: [simd_float4x4],
        modelMatrix: simd_float4x4,
        cameraMatrices: [simd_float4x4],
        cullEnabled: Bool = true,
        guardBand: Float = 0.2,
        reversed: Bool = false,
        resources: GPUSortResources,
        slotIndex: Int
    ) throws {
        precondition(!projectionMatrices.isEmpty, "Must have at least one projection matrix")
        precondition(projectionMatrices.count == cameraMatrices.count, "projectionMatrices and cameraMatrices must have the same count")
        precondition(projectionMatrices.count <= 2, "GPU sort supports at most two views")
        self.splatCloud = splatCloud
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.cullEnabled = cullEnabled
        self.guardBand = guardBand
        self.reversed = reversed
        self.resources = resources
        self.slotIndex = slotIndex

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SplatGPUSort")
        self.cullMark = try shaderLibrary.function(named: "splatCullMark", type: ComputeKernel.self)
        self.compactScanBlocks = try shaderLibrary.function(named: "splatCompactScanBlocks", type: ComputeKernel.self)
        self.compactScatter = try shaderLibrary.function(named: "splatCompactScatter", type: ComputeKernel.self)
        self.histogram = try shaderLibrary.function(named: "splatRadixHistogram", type: ComputeKernel.self)
        self.scanOffsets = try shaderLibrary.function(named: "splatRadixScanOffsets", type: ComputeKernel.self)
        self.scanDigitBase = try shaderLibrary.function(named: "splatRadixScanDigitBase", type: ComputeKernel.self)
        var scatterOff = FunctionConstants()
        scatterOff["decode_output"] = .bool(false)
        self.scatter = try shaderLibrary.function(named: "splatRadixScatter", type: ComputeKernel.self, constants: scatterOff)
        var scatterOn = FunctionConstants()
        scatterOn["decode_output"] = .bool(true)
        self.scatterDecode = try shaderLibrary.function(named: "splatRadixScatter", type: ComputeKernel.self, constants: scatterOn)
    }

    public var body: some Element {
        get throws {
            let count = splatCloud.count
            let slot = resources.slots[slotIndex]
            let modelViews = cameraMatrices.map { $0.inverse * modelMatrix * splatCloud.modelTransform }
            let viewCount = cameraMatrices.count

            let compactBlock = GPUSortResources.compactBlock
            let elementsPerTile = GPUSortResources.elementsPerTile
            let numBlocks = (count + compactBlock - 1) / compactBlock
            let numTiles = (count + elementsPerTile - 1) / elementsPerTile

            let distanceParams = SplatDistanceParams(
                modelView: modelViews[0],
                projection: projectionMatrices[0],
                modelView1: viewCount > 1 ? modelViews[1] : modelViews[0],
                projection1: viewCount > 1 ? projectionMatrices[1] : projectionMatrices[0],
                viewCount: UInt32(viewCount),
                numElements: UInt32(count),
                cloudIndex: 0,
                reversed: reversed ? 1 : 0,
                cullEnabled: cullEnabled ? 1 : 0,
                guardBand: guardBand
            )

            // Fixed 256-thread groups so block index == threadgroup index,
            // matching the compaction kernels' gid = group * COMPACT_BLOCK + lid.
            let blockGroups = MTLSize(width: numBlocks, height: 1, depth: 1)
            let blockThreads = MTLSize(width: compactBlock, height: 1, depth: 1)
            // One SIMD-group (32 threads) per 1024-element radix tile.
            let tileGroups = MTLSize(width: numTiles, height: 1, depth: 1)
            let tileThreads = MTLSize(width: 32, height: 1, depth: 1)
            let single = MTLSize(width: 1, height: 1, depth: 1)

            return try ComputePass(label: "GPU Splat Sort") {
                // Phase 1: cull + build records, tallying survivors per block.
                try ComputePipeline(computeKernel: cullMark) {
                    try ComputeDispatch(threadgroups: blockGroups, threadsPerThreadgroup: blockThreads)
                        .parameter("splats", buffer: splatCloud.splats.unsafeMTLBuffer)
                        .parameter("records", buffer: slot.recordsA)
                        .parameter("p", value: distanceParams)
                        .parameter("blockCounts", buffer: slot.blockCounts)
                }
                // Phase 2: scan per-block counts into base offsets + survivor
                // total (also writes the indirect draw args).
                try ComputePipeline(computeKernel: compactScanBlocks) {
                    try ComputeDispatch(threadsPerGrid: single, threadsPerThreadgroup: single)
                        .parameter("blockCounts", buffer: slot.blockCounts)
                        .parameter("blockBase", buffer: slot.blockBase)
                        .parameter("drawArgs", buffer: slot.drawArgs)
                        .parameter("numBlocks", value: UInt32(numBlocks))
                }
                // Phase 3: stable-compact survivors recordsA -> recordsB.
                try ComputePipeline(computeKernel: compactScatter) {
                    try ComputeDispatch(threadgroups: blockGroups, threadsPerThreadgroup: blockThreads)
                        .parameter("inRecords", buffer: slot.recordsA)
                        .parameter("outRecords", buffer: slot.recordsB)
                        .parameter("blockBase", buffer: slot.blockBase)
                        .parameter("numElements", value: UInt32(count))
                }
                // Two 8-bit radix passes over the 16-bit key. Pass 0 sorts
                // recordsB -> recordsA; pass 1 (decode) scatters directly into the
                // IndexedDistance output buffer, folding away the decode kernel.
                try radixPass(shift: 0, src: slot.recordsB, dst: slot.recordsA, decode: false, slot: slot, count: count, numTiles: numTiles, tileGroups: tileGroups, tileThreads: tileThreads, single: single)
                try radixPass(shift: 8, src: slot.recordsA, dst: slot.output.unsafeMTLBuffer, decode: true, slot: slot, count: count, numTiles: numTiles, tileGroups: tileGroups, tileThreads: tileThreads, single: single)
            }
        }
    }

    private func radixPass(shift: UInt32, src: MTLBuffer, dst: MTLBuffer, decode: Bool, slot: GPUSortResources.Slot, count: Int, numTiles: Int, tileGroups: MTLSize, tileThreads: MTLSize, single: MTLSize) throws -> some Element {
        let params = SplatSortParams(
            numElements: UInt32(count),
            numTiles: UInt32(numTiles),
            elementsPerTile: UInt32(GPUSortResources.elementsPerTile),
            shift: shift
        )
        return try Group {
            try ComputePipeline(computeKernel: histogram) {
                try ComputeDispatch(threadgroups: tileGroups, threadsPerThreadgroup: tileThreads)
                    .parameter("records", buffer: src)
                    .parameter("hist", buffer: slot.hist)
                    .parameter("p", value: params)
                    .parameter("drawArgs", buffer: slot.drawArgs)
            }
            try ComputePipeline(computeKernel: scanOffsets) {
                try ComputeDispatch(
                    threadsPerGrid: MTLSize(width: 256, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
                )
                .parameter("hist", buffer: slot.hist)
                .parameter("offset", buffer: slot.offset)
                .parameter("total", buffer: slot.total)
                .parameter("p", value: params)
                .parameter("drawArgs", buffer: slot.drawArgs)
            }
            try ComputePipeline(computeKernel: scanDigitBase) {
                try ComputeDispatch(threadsPerGrid: single, threadsPerThreadgroup: single)
                    .parameter("total", buffer: slot.total)
                    .parameter("digitBase", buffer: slot.digitBase)
            }
            try ComputePipeline(computeKernel: decode ? scatterDecode : scatter) {
                try ComputeDispatch(threadgroups: tileGroups, threadsPerThreadgroup: tileThreads)
                    .parameter("inRecords", buffer: src)
                    .parameter("outRecords", buffer: dst)
                    .parameter("offset", buffer: slot.offset)
                    .parameter("digitBase", buffer: slot.digitBase)
                    .parameter("p", value: params)
                    .parameter("drawArgs", buffer: slot.drawArgs)
            }
        }
    }
}

#endif
