#if !arch(x86_64)

import Metal
import MetalSprocketsGaussianSplatShaders

/// GPU work distribution for the PointSplat renderer (RFC 0003, Sec. 3.2).
///
/// Converts per-Gaussian point counts into a thread-to-Gaussian index map:
/// exclusive prefix sum, scatter, inclusive max-scan. The output `indices`
/// buffer maps each splat-thread `t` to the Gaussian it samples, sorted by
/// Gaussian index.
///
/// v0 performs a blocking CPU readback of the total point count between the
/// scatter and max-scan stages (RFC 0002's indirect-dispatch gap).
public final class PointSplatWorkloadDistributor {
    public enum DistributorError: Error {
        case bufferAllocationFailed
        case commandEncodingFailed
        case functionNotFound(String)
        case capacityExceeded(total: Int, capacity: Int)
    }

    /// Elements per scan block. Must match WORKLOAD_BLOCK in PointSplatWorkload.metal.
    static let blockSize = 256

    public struct Result {
        /// Maps splat-thread index to Gaussian index; valid in `[0, totalPoints)`.
        public let indices: MTLBuffer
        /// Total number of points to splat this frame (sum of all counts, clamped to capacity).
        public let totalPoints: Int
    }

    public let device: MTLDevice
    /// Maximum number of points per frame (T in the paper).
    public let capacity: Int

    private let scanCountsBlock: MTLComputePipelineState
    private let scanBlockSums: MTLComputePipelineState
    private let scatterIndices: MTLComputePipelineState
    private let maxScanBlock: MTLComputePipelineState
    private let scanBlockMaxes: MTLComputePipelineState
    private let applyBlockMax: MTLComputePipelineState

    private let indices: MTLBuffer
    private let totals: MTLBuffer

    public init(device: MTLDevice, capacity: Int) throws {
        self.device = device
        self.capacity = capacity

        let library = try device.makeDefaultLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: "PointSplatWorkload::\(name)") else {
                throw DistributorError.functionNotFound(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        scanCountsBlock = try pipeline("workloadScanCountsBlock")
        scanBlockSums = try pipeline("workloadScanBlockSums")
        scatterIndices = try pipeline("workloadScatterIndices")
        maxScanBlock = try pipeline("workloadMaxScanBlock")
        scanBlockMaxes = try pipeline("workloadScanBlockMaxes")
        applyBlockMax = try pipeline("workloadApplyBlockMax")

        guard let indices = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(capacity, 1), options: .storageModePrivate), let totals = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw DistributorError.bufferAllocationFailed
        }
        indices.label = "PointSplat indices"
        totals.label = "PointSplat totals"
        self.indices = indices
        self.totals = totals
    }

    /// Builds the thread-to-Gaussian map for the given per-Gaussian counts.
    /// Blocks until the GPU work completes.
    public func build(counts: MTLBuffer, count: Int, commandQueue: MTLCommandQueue) throws -> Result {
        let blockSize = Self.blockSize
        let numBlocks = (count + blockSize - 1) / blockSize
        var numElements = UInt32(count)
        var numBlocksValue = UInt32(numBlocks)
        var capacityValue = UInt32(capacity)

        guard let localPrefix = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(count, 1), options: .storageModePrivate), let blockScratchA = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(numBlocks, 1), options: .storageModePrivate), let blockScratchB = device.makeBuffer(length: MemoryLayout<UInt32>.stride * max(numBlocks, 1), options: .storageModePrivate) else {
            throw DistributorError.bufferAllocationFailed
        }

        let blockThreads = MTLSize(width: blockSize, height: 1, depth: 1)
        let single = MTLSize(width: 1, height: 1, depth: 1)

        // Stage A: prefix sums + scatter.
        guard let commandBufferA = commandQueue.makeCommandBuffer(), let blit = commandBufferA.makeBlitCommandEncoder() else {
            throw DistributorError.commandEncodingFailed
        }
        blit.fill(buffer: indices, range: 0..<indices.length, value: 0)
        blit.endEncoding()
        guard let encoderA = commandBufferA.makeComputeCommandEncoder() else {
            throw DistributorError.commandEncodingFailed
        }
        encoderA.setComputePipelineState(scanCountsBlock)
        encoderA.setBuffer(counts, offset: 0, index: 0)
        encoderA.setBuffer(localPrefix, offset: 0, index: 1)
        encoderA.setBuffer(blockScratchA, offset: 0, index: 2)
        encoderA.setBytes(&numElements, length: MemoryLayout<UInt32>.stride, index: 3)
        encoderA.dispatchThreadgroups(MTLSize(width: numBlocks, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)

        encoderA.setComputePipelineState(scanBlockSums)
        encoderA.setBuffer(blockScratchA, offset: 0, index: 0)
        encoderA.setBuffer(blockScratchB, offset: 0, index: 1)
        encoderA.setBuffer(totals, offset: 0, index: 2)
        encoderA.setBytes(&numBlocksValue, length: MemoryLayout<UInt32>.stride, index: 3)
        encoderA.dispatchThreadgroups(single, threadsPerThreadgroup: single)

        encoderA.setComputePipelineState(scatterIndices)
        encoderA.setBuffer(counts, offset: 0, index: 0)
        encoderA.setBuffer(localPrefix, offset: 0, index: 1)
        encoderA.setBuffer(blockScratchB, offset: 0, index: 2)
        encoderA.setBuffer(indices, offset: 0, index: 3)
        encoderA.setBytes(&numElements, length: MemoryLayout<UInt32>.stride, index: 4)
        encoderA.setBytes(&capacityValue, length: MemoryLayout<UInt32>.stride, index: 5)
        encoderA.dispatchThreadgroups(MTLSize(width: numBlocks, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
        encoderA.endEncoding()
        commandBufferA.commit()
        commandBufferA.waitUntilCompleted()

        let rawTotal = Int(totals.contents().load(as: UInt32.self))
        assert(rawTotal <= capacity, "PointSplat budget exceeded: \(rawTotal) > \(capacity); tail Gaussians will drop points")
        let totalPoints = min(rawTotal, capacity)
        if totalPoints == 0 {
            return Result(indices: indices, totalPoints: 0)
        }

        // Stage B: monotonic max-scan over [0, totalPoints).
        var totalElements = UInt32(totalPoints)
        let totalBlocks = (totalPoints + blockSize - 1) / blockSize
        var totalBlocksValue = UInt32(totalBlocks)
        guard let maxBlockMaxes = device.makeBuffer(length: MemoryLayout<UInt32>.stride * totalBlocks, options: .storageModePrivate), let maxBlockCarry = device.makeBuffer(length: MemoryLayout<UInt32>.stride * totalBlocks, options: .storageModePrivate) else {
            throw DistributorError.bufferAllocationFailed
        }
        guard let commandBufferB = commandQueue.makeCommandBuffer(), let encoderB = commandBufferB.makeComputeCommandEncoder() else {
            throw DistributorError.commandEncodingFailed
        }
        encoderB.setComputePipelineState(maxScanBlock)
        encoderB.setBuffer(indices, offset: 0, index: 0)
        encoderB.setBuffer(maxBlockMaxes, offset: 0, index: 1)
        encoderB.setBytes(&totalElements, length: MemoryLayout<UInt32>.stride, index: 2)
        encoderB.dispatchThreadgroups(MTLSize(width: totalBlocks, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)

        encoderB.setComputePipelineState(scanBlockMaxes)
        encoderB.setBuffer(maxBlockMaxes, offset: 0, index: 0)
        encoderB.setBuffer(maxBlockCarry, offset: 0, index: 1)
        encoderB.setBytes(&totalBlocksValue, length: MemoryLayout<UInt32>.stride, index: 2)
        encoderB.dispatchThreadgroups(single, threadsPerThreadgroup: single)

        encoderB.setComputePipelineState(applyBlockMax)
        encoderB.setBuffer(indices, offset: 0, index: 0)
        encoderB.setBuffer(maxBlockCarry, offset: 0, index: 1)
        encoderB.setBytes(&totalElements, length: MemoryLayout<UInt32>.stride, index: 2)
        encoderB.dispatchThreadgroups(MTLSize(width: totalBlocks, height: 1, depth: 1), threadsPerThreadgroup: blockThreads)
        encoderB.endEncoding()
        commandBufferB.commit()
        commandBufferB.waitUntilCompleted()

        return Result(indices: indices, totalPoints: totalPoints)
    }
}

#endif
