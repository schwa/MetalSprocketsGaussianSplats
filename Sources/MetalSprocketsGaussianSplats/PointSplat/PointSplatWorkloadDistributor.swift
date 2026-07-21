#if !arch(x86_64)

import Metal
import MetalSprockets
import MetalSprocketsGaussianSplatShaders

/// GPU work distribution for the PointSplat renderer (RFC 0003, Sec. 3.2).
///
/// Converts per-Gaussian point counts into a thread-to-Gaussian index map:
/// exclusive prefix sum, scatter, inclusive max-scan. The output `indices`
/// buffer maps each splat-thread `t` to the Gaussian it samples, sorted by
/// Gaussian index. The total point count lands in `totalsBuffer[0]` on the
/// GPU timeline, so consumers can stay readback-free by dispatching over
/// `capacity` and exiting threads past the total (RFC 0002's
/// indirect-dispatch gap).
final class PointSplatWorkloadDistributor {
    /// Elements per scan block. Must match WORKLOAD_BLOCK in PointSplatWorkload.metal.
    static let blockSize = 256

    /// Point budget per supersampled pixel. The paper's default budget
    /// (250M points at 1920x1080 with 2x2 supersampling) works out to
    /// ~30 points per pixel; 32 gives similar headroom. Cost: 4 bytes of
    /// index storage per point.
    static let pointsPerPixelBudget = 32

    /// Frame budget in *threads* (T / K) derived from the supersampled
    /// framebuffer size: 32 points per pixel, K points per thread. This is
    /// the distributor's capacity and the index-buffer length (4 bytes per
    /// thread).
    static func capacity(forSupersampledPixels pixels: Int, pointsPerThread: Int) -> Int {
        max(pixels, 1) * pointsPerPixelBudget / max(pointsPerThread, 1)
    }

    struct Result {
        /// Maps splat-thread index to Gaussian index; valid in `[0, totalPoints)`.
        let indices: MTLBuffer
        /// Total number of points to splat this frame (sum of all counts, clamped to capacity).
        let totalPoints: Int
    }

    let device: MTLDevice
    /// Maximum number of points per frame (T in the paper).
    let capacity: Int
    /// Maximum number of Gaussians per `elements` call.
    let maxSplats: Int

    /// Thread-to-Gaussian map, valid after the encoded work completes.
    let indicesBuffer: MTLBuffer
    /// Two uint32s, written on the GPU timeline: [0] the thread count after
    /// over-budget scaling (what the splat stage consumes), [1] the raw
    /// pre-scaling demand.
    let totalsBuffer: MTLBuffer

    /// Threads consumed by the last completed frame (post-scaling).
    var lastThreadCount: Int {
        Int(totalsBuffer.contents().load(as: UInt32.self))
    }

    /// Raw thread demand of the last completed frame; exceeds `capacity`
    /// when the scene wants more points than the budget allows.
    var lastThreadDemand: Int {
        Int(totalsBuffer.contents().load(fromByteOffset: MemoryLayout<UInt32>.stride, as: UInt32.self))
    }
    /// `MTLDispatchThreadgroupsIndirectArguments` for ceil(total/256)
    /// threadgroups, written on the GPU timeline. Use for any dispatch that
    /// should cover exactly the active threads (e.g. the splat stage).
    let dispatchArgsBuffer: MTLBuffer

    private let scanCountsBlock: ComputeKernel
    private let scaleCounts: ComputeKernel
    private let writeDispatchArgs: ComputeKernel
    private let scanBlockSums: ComputeKernel
    private let clearIndices: ComputeKernel
    private let scatterIndices: ComputeKernel
    private let maxScanBlock: ComputeKernel
    private let scanBlockMaxes: ComputeKernel
    private let applyBlockMax: ComputeKernel

    private let localPrefix: MTLBuffer
    private let countBlockSums: MTLBuffer
    private let countBlockBase: MTLBuffer
    private let maxBlockMaxes: MTLBuffer
    private let maxBlockCarry: MTLBuffer

    private var runner: Runner?

    init(device: MTLDevice, capacity: Int, maxSplats: Int) throws {
        self.device = device
        self.capacity = capacity
        self.maxSplats = maxSplats

        let library = try ShaderLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders).namespaced("PointSplatWorkload")
        scanCountsBlock = try library.function(named: "workloadScanCountsBlock", type: ComputeKernel.self)
        scaleCounts = try library.function(named: "workloadScaleCounts", type: ComputeKernel.self)
        scanBlockSums = try library.function(named: "workloadScanBlockSums", type: ComputeKernel.self)
        writeDispatchArgs = try library.function(named: "workloadWriteDispatchArgs", type: ComputeKernel.self)
        clearIndices = try library.function(named: "workloadClearIndices", type: ComputeKernel.self)
        scatterIndices = try library.function(named: "workloadScatterIndices", type: ComputeKernel.self)
        maxScanBlock = try library.function(named: "workloadMaxScanBlock", type: ComputeKernel.self)
        scanBlockMaxes = try library.function(named: "workloadScanBlockMaxes", type: ComputeKernel.self)
        applyBlockMax = try library.function(named: "workloadApplyBlockMax", type: ComputeKernel.self)

        let countBlocks = (maxSplats + Self.blockSize - 1) / Self.blockSize
        let capacityBlocks = (capacity + Self.blockSize - 1) / Self.blockSize
        let uintStride = MemoryLayout<UInt32>.stride
        guard let indices = device.makeBuffer(length: uintStride * max(capacity, 1), options: .storageModePrivate),
              let totals = device.makeBuffer(length: uintStride * 2, options: .storageModeShared),
              let dispatchArgs = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 4, options: .storageModePrivate),
              let localPrefix = device.makeBuffer(length: uintStride * max(maxSplats, 1), options: .storageModePrivate),
              let countBlockSums = device.makeBuffer(length: uintStride * max(countBlocks, 1), options: .storageModePrivate),
              let countBlockBase = device.makeBuffer(length: uintStride * max(countBlocks, 1), options: .storageModePrivate),
              let maxBlockMaxes = device.makeBuffer(length: uintStride * max(capacityBlocks, 1), options: .storageModePrivate),
              let maxBlockCarry = device.makeBuffer(length: uintStride * max(capacityBlocks, 1), options: .storageModePrivate) else {
            throw PointSplatError.bufferAllocationFailed
        }
        indices.label = "PointSplat indices"
        totals.label = "PointSplat totals"
        dispatchArgs.label = "PointSplat dispatch args"
        localPrefix.label = "PointSplat workload local prefix"
        countBlockSums.label = "PointSplat workload count block sums"
        countBlockBase.label = "PointSplat workload count block base"
        maxBlockMaxes.label = "PointSplat workload max block maxes"
        maxBlockCarry.label = "PointSplat workload max block carry"
        indicesBuffer = indices
        totalsBuffer = totals
        dispatchArgsBuffer = dispatchArgs
        self.localPrefix = localPrefix
        self.countBlockSums = countBlockSums
        self.countBlockBase = countBlockBase
        self.maxBlockMaxes = maxBlockMaxes
        self.maxBlockCarry = maxBlockCarry
    }

    /// The full distribution pipeline as compute elements for an enclosing
    /// ``ComputePass``. Every stage after the prefix sum dispatches
    /// indirectly from the GPU-side total, so cost scales with actual demand
    /// rather than capacity; entries past the total are garbage and must not
    /// be consumed.
    @ElementBuilder
    func elements(counts: MTLBuffer, count: Int, seed: UInt32 = 0) throws -> some Element {
        let blockSize = Self.blockSize
        let countBlocks = (max(count, 1) + blockSize - 1) / blockSize
        let numElements = UInt32(count)
        let numCountBlocks = UInt32(countBlocks)
        let capacityValue = UInt32(capacity)
        let uintStride = MemoryLayout<UInt32>.stride

        let blockThreads = MTLSize(width: blockSize, height: 1, depth: 1)
        let single = MTLSize(width: 1, height: 1, depth: 1)
        let countGroups = MTLSize(width: countBlocks, height: 1, depth: 1)

        try Group {
            // Pass A: raw demand into totals[1].
            try ComputePipeline(computeKernel: scanCountsBlock) {
                try ComputeDispatch(threadgroups: countGroups, threadsPerThreadgroup: blockThreads)
                    .parameter("counts", buffer: counts)
                    .parameter("localPrefix", buffer: localPrefix)
                    .parameter("blockSums", buffer: countBlockSums)
                    .parameter("numElements", value: numElements)
            }
            try ComputePipeline(computeKernel: scanBlockSums) {
                try ComputeDispatch(threadgroups: single, threadsPerThreadgroup: single)
                    .parameter("blockSums", buffer: countBlockSums)
                    .parameter("blockBase", buffer: countBlockBase)
                    .parameter("totals", buffer: totalsBuffer, offset: uintStride)
                    .parameter("numBlocks", value: numCountBlocks)
            }
            // Over-budget? Scale all counts down proportionally (stochastic
            // rounding keeps the expectation right), then re-scan. Turns budget
            // overflow into uniform noise instead of truncating whole regions.
            try ComputePipeline(computeKernel: scaleCounts) {
                try ComputeDispatch(threadgroups: countGroups, threadsPerThreadgroup: blockThreads)
                    .parameter("counts", buffer: counts)
                    .parameter("totals", buffer: totalsBuffer)
                    .parameter("capacity", value: capacityValue)
                    .parameter("numElements", value: numElements)
                    .parameter("seed", value: seed)
            }
            // Pass B: scan the (possibly scaled) counts into totals[0].
            try ComputePipeline(computeKernel: scanCountsBlock) {
                try ComputeDispatch(threadgroups: countGroups, threadsPerThreadgroup: blockThreads)
                    .parameter("counts", buffer: counts)
                    .parameter("localPrefix", buffer: localPrefix)
                    .parameter("blockSums", buffer: countBlockSums)
                    .parameter("numElements", value: numElements)
            }
            try ComputePipeline(computeKernel: scanBlockSums) {
                try ComputeDispatch(threadgroups: single, threadsPerThreadgroup: single)
                    .parameter("blockSums", buffer: countBlockSums)
                    .parameter("blockBase", buffer: countBlockBase)
                    .parameter("totals", buffer: totalsBuffer)
                    .parameter("numBlocks", value: numCountBlocks)
            }
            try ComputePipeline(computeKernel: writeDispatchArgs) {
                try ComputeDispatch(threadgroups: single, threadsPerThreadgroup: single)
                    .parameter("totals", buffer: totalsBuffer)
                    .parameter("capacity", value: capacityValue)
                    .parameter("args", buffer: dispatchArgsBuffer)
            }
        }
        try Group {
            try ComputePipeline(computeKernel: clearIndices) {
                try ComputeDispatch(indirectBuffer: dispatchArgsBuffer, threadsPerThreadgroup: blockThreads)
                    .parameter("indices", buffer: indicesBuffer)
                    .parameter("capacity", value: capacityValue)
            }
            try ComputePipeline(computeKernel: scatterIndices) {
                try ComputeDispatch(threadgroups: countGroups, threadsPerThreadgroup: blockThreads)
                    .parameter("counts", buffer: counts)
                    .parameter("localPrefix", buffer: localPrefix)
                    .parameter("blockBase", buffer: countBlockBase)
                    .parameter("indices", buffer: indicesBuffer)
                    .parameter("numElements", value: numElements)
                    .parameter("capacity", value: capacityValue)
            }
            try ComputePipeline(computeKernel: maxScanBlock) {
                try ComputeDispatch(indirectBuffer: dispatchArgsBuffer, threadsPerThreadgroup: blockThreads)
                    .parameter("indices", buffer: indicesBuffer)
                    .parameter("blockMaxes", buffer: maxBlockMaxes)
                    .parameter("totals", buffer: totalsBuffer)
                    .parameter("capacity", value: capacityValue)
            }
            try ComputePipeline(computeKernel: scanBlockMaxes) {
                try ComputeDispatch(threadgroups: single, threadsPerThreadgroup: single)
                    .parameter("blockMaxes", buffer: maxBlockMaxes)
                    .parameter("blockCarry", buffer: maxBlockCarry)
                    .parameter("totals", buffer: totalsBuffer)
                    .parameter("capacity", value: capacityValue)
            }
            try ComputePipeline(computeKernel: applyBlockMax) {
                try ComputeDispatch(indirectBuffer: dispatchArgsBuffer, threadsPerThreadgroup: blockThreads)
                    .parameter("indices", buffer: indicesBuffer)
                    .parameter("blockCarry", buffer: maxBlockCarry)
                    .parameter("totals", buffer: totalsBuffer)
                    .parameter("capacity", value: capacityValue)
            }
        }
    }

    /// Validates `count` before building the element tree.
    func validate(count: Int) throws {
        guard count <= maxSplats else {
            throw PointSplatError.splatCountExceedsMaximum(count: count, maximum: maxSplats)
        }
    }

    /// Builds the thread-to-Gaussian map, blocking until the GPU work
    /// completes, and reads back the total. Convenience for offline/test use.
    func build(counts: MTLBuffer, count: Int, commandQueue: MTLCommandQueue) throws -> Result {
        try validate(count: count)
        let runner: Runner
        if let existing = self.runner {
            runner = existing
        } else {
            runner = try Runner(device: device, commandQueue: commandQueue)
            self.runner = runner
        }
        try runner.run(
            ComputePass(label: "PointSplat workload") {
                try elements(counts: counts, count: count)
            }
        )

        let rawTotal = Int(totalsBuffer.contents().load(as: UInt32.self))
        // Stochastic rounding in the over-budget scaling pass can land a
        // hair above capacity; consumption is clamped either way.
        return Result(indices: indicesBuffer, totalPoints: min(rawTotal, capacity))
    }
}

#endif
