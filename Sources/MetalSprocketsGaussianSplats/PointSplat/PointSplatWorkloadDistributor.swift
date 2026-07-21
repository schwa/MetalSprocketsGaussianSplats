#if !arch(x86_64)

import Metal
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
public final class PointSplatWorkloadDistributor {
    public enum DistributorError: Error {
        case bufferAllocationFailed
        case commandEncodingFailed
        case functionNotFound(String)
        case splatCountExceedsMaximum(count: Int, maximum: Int)
    }

    /// Elements per scan block. Must match WORKLOAD_BLOCK in PointSplatWorkload.metal.
    static let blockSize = 256

    /// Point budget per supersampled pixel. The paper's default budget
    /// (250M points at 1920x1080 with 2x2 supersampling) works out to
    /// ~30 points per pixel; 32 gives similar headroom. Cost: 4 bytes of
    /// index storage per point.
    static let pointsPerPixelBudget = 32

    /// Frame point budget (T) derived from the supersampled framebuffer size.
    public static func capacity(forSupersampledPixels pixels: Int) -> Int {
        max(pixels, 1) * pointsPerPixelBudget
    }

    public struct Result {
        /// Maps splat-thread index to Gaussian index; valid in `[0, totalPoints)`.
        public let indices: MTLBuffer
        /// Total number of points to splat this frame (sum of all counts, clamped to capacity).
        public let totalPoints: Int
    }

    public let device: MTLDevice
    /// Maximum number of points per frame (T in the paper).
    public let capacity: Int
    /// Maximum number of Gaussians per `encode` call.
    public let maxSplats: Int

    /// Thread-to-Gaussian map, valid after the encoded work completes.
    public let indicesBuffer: MTLBuffer
    /// One uint32: the total point count, written on the GPU timeline.
    public let totalsBuffer: MTLBuffer

    private let scanCountsBlock: MTLComputePipelineState
    private let scanBlockSums: MTLComputePipelineState
    private let clearIndices: MTLComputePipelineState
    private let scatterIndices: MTLComputePipelineState
    private let maxScanBlock: MTLComputePipelineState
    private let scanBlockMaxes: MTLComputePipelineState
    private let applyBlockMax: MTLComputePipelineState

    private let localPrefix: MTLBuffer
    private let countBlockSums: MTLBuffer
    private let countBlockBase: MTLBuffer
    private let maxBlockMaxes: MTLBuffer
    private let maxBlockCarry: MTLBuffer

    public init(device: MTLDevice, capacity: Int, maxSplats: Int) throws {
        self.device = device
        self.capacity = capacity
        self.maxSplats = maxSplats

        let library = try device.makeDefaultLibrary(bundle: Bundle.metalSprocketsGaussianSplatShaders)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: "PointSplatWorkload::\(name)") else {
                throw DistributorError.functionNotFound(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        scanCountsBlock = try pipeline("workloadScanCountsBlock")
        scanBlockSums = try pipeline("workloadScanBlockSums")
        clearIndices = try pipeline("workloadClearIndices")
        scatterIndices = try pipeline("workloadScatterIndices")
        maxScanBlock = try pipeline("workloadMaxScanBlock")
        scanBlockMaxes = try pipeline("workloadScanBlockMaxes")
        applyBlockMax = try pipeline("workloadApplyBlockMax")

        let countBlocks = (maxSplats + Self.blockSize - 1) / Self.blockSize
        let capacityBlocks = (capacity + Self.blockSize - 1) / Self.blockSize
        let uintStride = MemoryLayout<UInt32>.stride
        guard let indices = device.makeBuffer(length: uintStride * max(capacity, 1), options: .storageModePrivate),
              let totals = device.makeBuffer(length: uintStride, options: .storageModeShared),
              let localPrefix = device.makeBuffer(length: uintStride * max(maxSplats, 1), options: .storageModePrivate),
              let countBlockSums = device.makeBuffer(length: uintStride * max(countBlocks, 1), options: .storageModePrivate),
              let countBlockBase = device.makeBuffer(length: uintStride * max(countBlocks, 1), options: .storageModePrivate),
              let maxBlockMaxes = device.makeBuffer(length: uintStride * max(capacityBlocks, 1), options: .storageModePrivate),
              let maxBlockCarry = device.makeBuffer(length: uintStride * max(capacityBlocks, 1), options: .storageModePrivate) else {
            throw DistributorError.bufferAllocationFailed
        }
        indices.label = "PointSplat indices"
        totals.label = "PointSplat totals"
        indicesBuffer = indices
        totalsBuffer = totals
        self.localPrefix = localPrefix
        self.countBlockSums = countBlockSums
        self.countBlockBase = countBlockBase
        self.maxBlockMaxes = maxBlockMaxes
        self.maxBlockCarry = maxBlockCarry
    }

    /// Encodes the full distribution pipeline into an open compute encoder.
    /// The max-scan is sized to `capacity` so no CPU readback is required;
    /// entries past the total are garbage and must not be consumed.
    public func encode(encoder: MTLComputeCommandEncoder, counts: MTLBuffer, count: Int) throws {
        guard count <= maxSplats else {
            throw DistributorError.splatCountExceedsMaximum(count: count, maximum: maxSplats)
        }
        let blockSize = Self.blockSize
        let countBlocks = (count + blockSize - 1) / blockSize
        let capacityBlocks = (capacity + blockSize - 1) / blockSize
        var numElements = UInt32(count)
        var numCountBlocks = UInt32(countBlocks)
        var capacityValue = UInt32(capacity)
        var numCapacityBlocks = UInt32(capacityBlocks)

        let blockThreads = MTLSize(width: blockSize, height: 1, depth: 1)
        let single = MTLSize(width: 1, height: 1, depth: 1)
        let countGroups = MTLSize(width: countBlocks, height: 1, depth: 1)
        let capacityGroups = MTLSize(width: capacityBlocks, height: 1, depth: 1)
        let uintStride = MemoryLayout<UInt32>.stride

        encoder.setComputePipelineState(scanCountsBlock)
        encoder.setBuffer(counts, offset: 0, index: 0)
        encoder.setBuffer(localPrefix, offset: 0, index: 1)
        encoder.setBuffer(countBlockSums, offset: 0, index: 2)
        encoder.setBytes(&numElements, length: uintStride, index: 3)
        encoder.dispatchThreadgroups(countGroups, threadsPerThreadgroup: blockThreads)

        encoder.setComputePipelineState(scanBlockSums)
        encoder.setBuffer(countBlockSums, offset: 0, index: 0)
        encoder.setBuffer(countBlockBase, offset: 0, index: 1)
        encoder.setBuffer(totalsBuffer, offset: 0, index: 2)
        encoder.setBytes(&numCountBlocks, length: uintStride, index: 3)
        encoder.dispatchThreadgroups(single, threadsPerThreadgroup: single)

        encoder.setComputePipelineState(clearIndices)
        encoder.setBuffer(indicesBuffer, offset: 0, index: 0)
        encoder.setBytes(&capacityValue, length: uintStride, index: 1)
        encoder.dispatchThreadgroups(capacityGroups, threadsPerThreadgroup: blockThreads)

        encoder.setComputePipelineState(scatterIndices)
        encoder.setBuffer(counts, offset: 0, index: 0)
        encoder.setBuffer(localPrefix, offset: 0, index: 1)
        encoder.setBuffer(countBlockBase, offset: 0, index: 2)
        encoder.setBuffer(indicesBuffer, offset: 0, index: 3)
        encoder.setBytes(&numElements, length: uintStride, index: 4)
        encoder.setBytes(&capacityValue, length: uintStride, index: 5)
        encoder.dispatchThreadgroups(countGroups, threadsPerThreadgroup: blockThreads)

        encoder.setComputePipelineState(maxScanBlock)
        encoder.setBuffer(indicesBuffer, offset: 0, index: 0)
        encoder.setBuffer(maxBlockMaxes, offset: 0, index: 1)
        encoder.setBytes(&capacityValue, length: uintStride, index: 2)
        encoder.dispatchThreadgroups(capacityGroups, threadsPerThreadgroup: blockThreads)

        encoder.setComputePipelineState(scanBlockMaxes)
        encoder.setBuffer(maxBlockMaxes, offset: 0, index: 0)
        encoder.setBuffer(maxBlockCarry, offset: 0, index: 1)
        encoder.setBytes(&numCapacityBlocks, length: uintStride, index: 2)
        encoder.dispatchThreadgroups(single, threadsPerThreadgroup: single)

        encoder.setComputePipelineState(applyBlockMax)
        encoder.setBuffer(indicesBuffer, offset: 0, index: 0)
        encoder.setBuffer(maxBlockCarry, offset: 0, index: 1)
        encoder.setBytes(&capacityValue, length: uintStride, index: 2)
        encoder.dispatchThreadgroups(capacityGroups, threadsPerThreadgroup: blockThreads)
    }

    /// Builds the thread-to-Gaussian map, blocking until the GPU work
    /// completes, and reads back the total. Convenience for offline/test use.
    public func build(counts: MTLBuffer, count: Int, commandQueue: MTLCommandQueue) throws -> Result {
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DistributorError.commandEncodingFailed
        }
        try encode(encoder: encoder, counts: counts, count: count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let rawTotal = Int(totalsBuffer.contents().load(as: UInt32.self))
        assert(rawTotal <= capacity, "PointSplat budget exceeded: \(rawTotal) > \(capacity); tail Gaussians will drop points")
        return Result(indices: indicesBuffer, totalPoints: min(rawTotal, capacity))
    }
}

#endif
