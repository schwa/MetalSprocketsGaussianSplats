#if !arch(x86_64)

import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
import Splats

/// Compute pass encoding the full GPU splat sort for one or more clouds into one slot of
/// a ``GPUSortResources``: frustum cull + stable compaction, then a two- or four-pass
/// 8-bit LSD radix over the selected depth-key precision, then decode into
/// `IndexedDistance` records the render vertex shader reads.
///
/// Culled splats are dropped before the radix, so the sort processes only
/// survivors. The survivor count lands in the slot's indirect draw args
/// (`instanceCount`) for the render pass to draw with.
///
/// With several clouds, all splats are merged into one back-to-front order and
/// each output record carries its `cloudIndex` and the splat's index in that
/// cloud. Size the resources with ``GPUSortResources/requiredCapacity(for:)``.
public struct GPUSplatSortComputePass: Element {
    var splatClouds: [GPUSplatCloud<SparkSplat>]
    var projectionMatrices: [simd_float4x4]
    var modelMatrix: simd_float4x4
    var cameraMatrices: [simd_float4x4]
    var cullEnabled: Bool
    var guardBand: Float
    var reversed: Bool
    var resources: GPUSortResources
    var slotIndex: Int

    let cullMark: ComputeKernel
    @MSState var compactScanBlocks: ComputeKernel
    @MSState var compactScatter: ComputeKernel
    @MSState var histogram: ComputeKernel
    @MSState var scanOffsets: ComputeKernel
    @MSState var scanDigitBase: ComputeKernel
    let scatter: ComputeKernel        // decode_output = false
    let scatterDecode: ComputeKernel  // decode_output = true (final pass)

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

    /// Single-cloud initializer supporting stereo.
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
        try self.init(
            splatClouds: [splatCloud],
            projectionMatrices: projectionMatrices,
            modelMatrix: modelMatrix,
            cameraMatrices: cameraMatrices,
            cullEnabled: cullEnabled,
            guardBand: guardBand,
            reversed: reversed,
            resources: resources,
            slotIndex: slotIndex
        )
    }

    /// Full initializer supporting several clouds and stereo. With two views the
    /// cull keeps any splat visible to either view. The sort key is the first view's depth.
    public init(
        splatClouds: [GPUSplatCloud<SparkSplat>],
        projectionMatrices: [simd_float4x4],
        modelMatrix: simd_float4x4,
        cameraMatrices: [simd_float4x4],
        cullEnabled: Bool = true,
        guardBand: Float = 0.2,
        reversed: Bool = false,
        resources: GPUSortResources,
        slotIndex: Int
    ) throws {
        precondition(!splatClouds.isEmpty, "Must have at least one splat cloud")
        precondition(splatClouds.count <= Int(UInt16.max), "cloudIndex is 16-bit")
        precondition(!projectionMatrices.isEmpty, "Must have at least one projection matrix")
        precondition(projectionMatrices.count == cameraMatrices.count, "projectionMatrices and cameraMatrices must have the same count")
        precondition(projectionMatrices.count <= 2, "GPU sort supports at most two views")
        self.splatClouds = splatClouds
        self.projectionMatrices = projectionMatrices
        self.modelMatrix = modelMatrix
        self.cameraMatrices = cameraMatrices
        self.cullEnabled = cullEnabled
        self.guardBand = guardBand
        self.reversed = reversed
        self.resources = resources
        self.slotIndex = slotIndex

        let shaderLibrary = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("SplatGPUSort")
        var keyConstants = FunctionConstants()
        keyConstants["use_float32_keys"] = .bool(resources.precision == .float32)
        self.cullMark = try shaderLibrary.function(named: "splatCullMark", type: ComputeKernel.self, constants: keyConstants)
        self.compactScanBlocks = try shaderLibrary.function(named: "splatCompactScanBlocks", type: ComputeKernel.self)
        self.compactScatter = try shaderLibrary.function(named: "splatCompactScatter", type: ComputeKernel.self)
        self.histogram = try shaderLibrary.function(named: "splatRadixHistogram", type: ComputeKernel.self)
        self.scanOffsets = try shaderLibrary.function(named: "splatRadixScanOffsets", type: ComputeKernel.self)
        self.scanDigitBase = try shaderLibrary.function(named: "splatRadixScanDigitBase", type: ComputeKernel.self)
        var scatterOff = keyConstants
        scatterOff["decode_output"] = .bool(false)
        self.scatter = try shaderLibrary.function(named: "splatRadixScatter", type: ComputeKernel.self, constants: scatterOff)
        var scatterOn = keyConstants
        scatterOn["decode_output"] = .bool(true)
        self.scatterDecode = try shaderLibrary.function(named: "splatRadixScatter", type: ComputeKernel.self, constants: scatterOn)
    }

    public var body: some Element {
        get throws {
            let slot = resources.slots[slotIndex]
            let viewCount = cameraMatrices.count
            let compactBlock = GPUSortResources.compactBlock
            let elementsPerTile = GPUSortResources.elementsPerTile

            // Each cloud gets its own range of compaction blocks and global indices.
            var cloudBases: [UInt32] = []
            var cullDispatches: [(cloud: GPUSplatCloud<SparkSplat>, params: SplatDistanceParams, blocks: Int)] = []
            var count = 0
            var numBlocks = 0
            for cloud in splatClouds {
                let modelViews = cameraMatrices.map { $0.inverse * modelMatrix * cloud.modelTransform }
                let cloudBlocks = (cloud.count + compactBlock - 1) / compactBlock
                let params = SplatDistanceParams(
                    modelView: modelViews[0],
                    projection: projectionMatrices[0],
                    modelView1: viewCount > 1 ? modelViews[1] : modelViews[0],
                    projection1: viewCount > 1 ? projectionMatrices[1] : projectionMatrices[0],
                    viewCount: UInt32(viewCount),
                    numElements: UInt32(cloud.count),
                    blockOffset: UInt32(numBlocks),
                    indexBase: UInt32(count),
                    reversed: reversed ? 1 : 0,
                    cullEnabled: cullEnabled ? 1 : 0,
                    guardBand: guardBand
                )
                cloudBases.append(UInt32(count))
                cullDispatches.append((cloud, params, cloudBlocks))
                count += cloud.count
                numBlocks += cloudBlocks
            }
            precondition(numBlocks * compactBlock <= resources.capacity || splatClouds.count == 1, "GPUSortResources too small; use requiredCapacity(for:)")
            let numTiles = (count + elementsPerTile - 1) / elementsPerTile

            // Fixed 512-thread groups so block index == threadgroup index,
            // matching the compaction kernels' gid = group * COMPACT_BLOCK + lid.
            let blockGroups = MTLSize(width: numBlocks, height: 1, depth: 1)
            let blockThreads = MTLSize(width: compactBlock, height: 1, depth: 1)
            // One SIMD-group (32 threads) per 1024-element radix tile.
            let tileGroups = MTLSize(width: numTiles, height: 1, depth: 1)
            let tileThreads = MTLSize(width: 32, height: 1, depth: 1)
            let single = MTLSize(width: 1, height: 1, depth: 1)

            return try ComputePass(label: "GPU Splat Sort") {
                // Phase 1: cull + build records, tallying survivors per block.
                // Clouds write disjoint block ranges, so they need no barrier between them.
                ForEach(Array(cullDispatches.enumerated()), id: \.offset) { _, dispatch in
                    try ComputePipeline(computeKernel: cullMark) {
                        try ComputeDispatch(threadgroups: MTLSize(width: dispatch.blocks, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
                            .parameter("splats", buffer: dispatch.cloud.splats.unsafeMTLBuffer)
                            .parameter("records", buffer: slot.recordsA)
                            .parameter("p", value: dispatch.params)
                            .parameter("blockCounts", buffer: slot.blockCounts)
                    }
                }
                EncoderBarrier(after: .dispatch, before: .dispatch)
                // Phase 2: scan per-block counts into base offsets + survivor
                // total (also writes the indirect draw args).
                try ComputePipeline(computeKernel: compactScanBlocks) {
                    try ComputeDispatch(threadsPerGrid: single, threadsPerThreadgroup: single)
                        .parameter("blockCounts", buffer: slot.blockCounts)
                        .parameter("blockBase", buffer: slot.blockBase)
                        .parameter("drawArgs", buffer: slot.drawArgs)
                        .parameter("numBlocks", value: UInt32(numBlocks))
                }
                EncoderBarrier(after: .dispatch, before: .dispatch)
                // Phase 3: stable-compact survivors recordsA -> recordsB.
                try ComputePipeline(computeKernel: compactScatter) {
                    try ComputeDispatch(threadgroups: blockGroups, threadsPerThreadgroup: blockThreads)
                        .parameter("inRecords", buffer: slot.recordsA)
                        .parameter("outRecords", buffer: slot.recordsB)
                        .parameter("blockBase", buffer: slot.blockBase)
                        .parameter("blockCounts", buffer: slot.blockCounts)
                }
                EncoderBarrier(after: .dispatch, before: .dispatch)
                // Each radix pass reads the previous pass's output; the pass
                // itself inserts barriers between its own stages, and these
                // barriers order one pass after the next.
                // Only the final pass decodes into the IndexedDistance output.
                try radixPass(shift: 0, src: slot.recordsB, dst: slot.recordsA, decode: false, slot: slot, count: count, numTiles: numTiles, tileGroups: tileGroups, tileThreads: tileThreads, single: single)
                EncoderBarrier(after: .dispatch, before: .dispatch)
                if resources.precision == .float32 {
                    try radixPass(shift: 8, src: slot.recordsA, dst: slot.recordsB, decode: false, slot: slot, count: count, numTiles: numTiles, tileGroups: tileGroups, tileThreads: tileThreads, single: single)
                    EncoderBarrier(after: .dispatch, before: .dispatch)
                    try radixPass(shift: 16, src: slot.recordsB, dst: slot.recordsA, decode: false, slot: slot, count: count, numTiles: numTiles, tileGroups: tileGroups, tileThreads: tileThreads, single: single)
                    EncoderBarrier(after: .dispatch, before: .dispatch)
                    try radixPass(shift: 24, src: slot.recordsA, dst: slot.output.unsafeMTLBuffer, decode: true, slot: slot, count: count, numTiles: numTiles, tileGroups: tileGroups, tileThreads: tileThreads, single: single, cloudBases: cloudBases)
                } else {
                    try radixPass(shift: 8, src: slot.recordsA, dst: slot.output.unsafeMTLBuffer, decode: true, slot: slot, count: count, numTiles: numTiles, tileGroups: tileGroups, tileThreads: tileThreads, single: single, cloudBases: cloudBases)
                }
            }
            // Metal 4 does not order encoders. Every consumer draws from the sorted indices and the indirect
            // draw args, so order the vertex stage of later passes after this pass.
            .barrierAfterPass(after: .dispatch, beforeQueueStages: .vertex)
            .useResourceCollection(resources.resourceCollection)
            .useResources(of: splatClouds)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func radixPass(shift: UInt32, src: MTLBuffer, dst: MTLBuffer, decode: Bool, slot: GPUSortResources.Slot, count: Int, numTiles: Int, tileGroups: MTLSize, tileThreads: MTLSize, single: MTLSize, cloudBases: [UInt32] = []) throws -> AnyElement {
        let params = SplatSortParams(
            numElements: UInt32(count),
            numTiles: UInt32(numTiles),
            elementsPerTile: UInt32(GPUSortResources.elementsPerTile),
            shift: shift
        )
        // Dependent dispatches: Metal 4 does not auto-serialize, so order each
        // stage against the previous with an encoder barrier.
        return try Group {
            try ComputePipeline(computeKernel: histogram) {
                try ComputeDispatch(threadgroups: tileGroups, threadsPerThreadgroup: tileThreads)
                    .parameter("records", buffer: src)
                    .parameter("hist", buffer: slot.hist)
                    .parameter("p", value: params)
                    .parameter("drawArgs", buffer: slot.drawArgs)
            }
            EncoderBarrier(after: .dispatch, before: .dispatch)
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
            EncoderBarrier(after: .dispatch, before: .dispatch)
            try ComputePipeline(computeKernel: scanDigitBase) {
                try ComputeDispatch(threadsPerGrid: single, threadsPerThreadgroup: single)
                    .parameter("total", buffer: slot.total)
                    .parameter("digitBase", buffer: slot.digitBase)
            }
            EncoderBarrier(after: .dispatch, before: .dispatch)
            try ComputePipeline(computeKernel: decode ? scatterDecode : scatter) {
                let dispatch = try ComputeDispatch(threadgroups: tileGroups, threadsPerThreadgroup: tileThreads)
                    .parameter("inRecords", buffer: src)
                    .parameter("outRecords", buffer: dst)
                    .parameter("offset", buffer: slot.offset)
                    .parameter("digitBase", buffer: slot.digitBase)
                    .parameter("p", value: params)
                    .parameter("drawArgs", buffer: slot.drawArgs)
                if decode {
                    dispatch
                        .parameter("cloudBases", values: cloudBases)
                        .parameter("cloudCount", value: UInt32(cloudBases.count))
                } else {
                    dispatch
                }
            }
        }
        .eraseToAnyElement()
    }
}

#endif
