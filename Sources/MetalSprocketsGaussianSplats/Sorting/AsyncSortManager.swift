#if !arch(x86_64)
import Dispatch
@preconcurrency import Metal
import MetalSprocketsGaussianSplatShaders
internal import os
import simd
import Splats
import Synchronization

/// Assert that we're not on the main thread
@inline(__always)
private func assertNotMainThread(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    assert(!Thread.isMainThread, "\(message()) should not be called on main thread", file: file, line: line)
}

/// Statistics from a completed sort operation
public struct SortEvent: Sendable {
    public var time: Date
    public var duration: TimeInterval
    public var splatCount: Int
    public var cloudCount: Int

    public init(time: Date, duration: TimeInterval, splatCount: Int, cloudCount: Int) {
        self.time = time
        self.duration = duration
        self.splatCount = splatCount
        self.cloudCount = cloudCount
    }
}

/// Manages asynchronous sorting of Gaussian splat clouds by distance from the camera.
///
/// The sort manager runs sorts on a background thread and publishes results via
/// ``sortedIndicesStream``. It is intended to be owned by the caller (typically a
/// SwiftUI view or view model), not by the render pipeline.
///
/// ## Typical Usage
///
/// 1. Create a sort manager with one or more splat clouds.
/// 2. Subscribe to ``sortedIndicesStream`` to receive sorted indices as they complete.
/// 3. Call ``requestSort(_:)`` whenever the camera or model matrix changes.
/// 4. Pass the received ``SplatIndices`` to a render pipeline.
/// 5. Return used index buffers to ``indexBufferPool`` in your command buffer's completion handler.
///
/// ```swift
/// let sortManager = try AsyncSortManager(device: device, splatCloud: cloud, capacity: cloud.count)
///
/// // In a .task:
/// for await indices in sortManager.sortedIndicesStream {
///     self.sortedIndices = indices
/// }
///
/// // On camera change:
/// sortManager.requestSort(SortParameters(camera: cameraMatrix, model: modelMatrix))
///
/// // When receiving new indices, release the old ones:
/// for await indices in sortManager.sortedIndicesStream {
///     if let old = sortedIndices {
///         sortManager.release(old)
///     }
///     sortedIndices = indices
/// }
/// ```
///
/// For single-frame offline rendering, use ``sortNowSync(_:)`` instead.
public actor AsyncSortManager<Splat> where Splat: SortableSplatProtocol {
    private var splatClouds: [GPUSplatCloud<Splat>]
    private let _sortRequestStream = SingleValueStream<SortParameters>()
    private let _sortedIndicesStream = SingleValueStream<SplatIndices>()
    private let _sortEventStream = SingleValueStream<SortEvent>()
    private var logger: Logger?
    private var sorter: CPUSplatRadixSorter<Splat>
    nonisolated(unsafe) private var sortingTask: Task<Void, Never>?
    private let device: MTLDevice
    private var capacity: Int
    nonisolated(unsafe) private var _indexBufferPool: Pool<TypedMTLBuffer<IndexedDistance>>

    /// Whether at least one sort has completed
    public private(set) var isSorted: Bool = false

    /// The current capacity of the internal sorter. Exposed for testing.
    internal var sorterCapacity: Int {
        sorter.capacity
    }

    /// The most recent sorted indices (nil until first sort completes)
    public private(set) var currentSortedIndices: SplatIndices?

    /// Initialize with multiple clouds
    ///
    /// - Parameters:
    ///   - device: The Metal device to use for buffer allocation.
    ///   - splatClouds: The splat clouds to sort.
    ///   - capacity: Maximum number of splats the sorter can handle.
    ///   - preallocatedBufferCount: Number of index buffers to preallocate in the pool.
    ///     Typical value is 4 (in-flight MTKView buffers + 1 for sorting). Default is 0
    ///     which allocates buffers on demand.
    public init(device: MTLDevice, splatClouds: [GPUSplatCloud<Splat>], capacity: Int, preallocatedBufferCount: Int = 0) throws {
        self.device = device
        self.capacity = capacity
        self.sorter = .init(device: device, capacity: capacity)
        self.splatClouds = splatClouds
        self.logger = nil
        self._indexBufferPool = Self.makeIndexBufferPool(device: device, capacity: capacity, preallocatedCount: preallocatedBufferCount)
        let stream = _sortRequestStream
        self.sortingTask = Task(priority: .high) { [weak self] in
            for await parameters in stream {
                guard let self else { break }
                do {
                    try await self.processSortRequest(parameters, logger: nil)
                } catch is CancellationError {
                    break
                } catch {
                    // Silently fail - no logger
                }
            }
        }
    }

    /// Internal initializer with logger support
    internal init(device: MTLDevice, splatClouds: [GPUSplatCloud<Splat>], capacity: Int, preallocatedBufferCount: Int = 0, logger: Logger?) throws {
        self.device = device
        self.capacity = capacity
        self.sorter = .init(device: device, capacity: capacity)
        self.splatClouds = splatClouds
        self.logger = logger
        self._indexBufferPool = Self.makeIndexBufferPool(device: device, capacity: capacity, preallocatedCount: preallocatedBufferCount)
        let stream = _sortRequestStream
        self.sortingTask = Task(priority: .high) { [weak self] in
            for await parameters in stream {
                guard let self else { break }
                do {
                    try await self.processSortRequest(parameters, logger: logger)
                } catch is CancellationError {
                    break
                } catch {
                    logger?.log("Failed to sort splats: \(error)")
                }
            }
        }
    }

    /// Convenience initializer for single cloud
    public init(device: MTLDevice, splatCloud: GPUSplatCloud<Splat>, capacity: Int, preallocatedBufferCount: Int = 0) throws {
        try self.init(device: device, splatClouds: [splatCloud], capacity: capacity, preallocatedBufferCount: preallocatedBufferCount)
    }

    deinit {
        sortingTask?.cancel()
        _sortRequestStream.finish()
        _sortedIndicesStream.finish()
        _sortEventStream.finish()
    }

    /// Stream of sorted indices, updated after each completed sort.
    ///
    /// Subscribe with `for await` to receive the latest sorted indices.
    /// Old values are dropped if not consumed — only the most recent sort matters.
    ///
    /// ```swift
    /// for await indices in sortManager.sortedIndicesStream {
    ///     self.sortedIndices = indices
    /// }
    /// ```
    nonisolated public var sortedIndicesStream: SingleValueStream<SplatIndices> {
        _sortedIndicesStream
    }

    /// Stream of sort timing events, updated after each completed sort.
    ///
    /// Useful for performance monitoring and UI display of sort statistics.
    nonisolated public var sortEventStream: SingleValueStream<SortEvent> {
        _sortEventStream
    }

    /// Pool of index buffers for reuse.
    ///
    /// Use ``release(_:)`` to return buffers to the pool when they are no longer needed.
    ///
    /// If buffers are not released, the pool will allocate new buffers on each sort
    /// (with a warning logged), defeating the purpose of pooling.
    nonisolated public var indexBufferPool: Pool<TypedMTLBuffer<IndexedDistance>> {
        _indexBufferPool
    }

    /// Release sorted indices back to the pool for reuse.
    ///
    /// Call this when you receive new indices and are done with the old ones:
    ///
    /// ```swift
    /// for await indices in sortManager.sortedIndicesStream {
    ///     if let old = sortedIndices {
    ///         sortManager.release(old)
    ///     }
    ///     sortedIndices = indices
    /// }
    /// ```
    ///
    /// - Parameter indices: The sorted indices to release.
    nonisolated public func release(_ indices: SplatIndices) {
        _indexBufferPool.release(indices.indices)
    }

    /// Replace the active splat clouds without recreating the sort manager.
    ///
    /// If the combined splat count of the new clouds exceeds the sorter's current
    /// capacity, the internal scratch buffer is grown automatically and a new buffer
    /// pool is created. The old pool drains naturally as GPU completions return buffers.
    ///
    /// The existing ``currentSortedIndices`` are deliberately **not** cleared — the stale
    /// indices remain available for rendering until the next sort completes, preventing a
    /// blank frame on every cloud switch.
    ///
    /// After calling this, request a fresh sort to update the indices:
    ///
    /// ```swift
    /// await sortManager.setSplatClouds([newCloud])
    /// sortManager.requestSort(SortParameters(camera: cameraMatrix, model: .identity))
    /// ```
    public func setSplatClouds(_ clouds: [GPUSplatCloud<Splat>]) {
        splatClouds = clouds
        let totalCount = clouds.reduce(0) { $0 + $1.count }
        if totalCount != capacity {
            resize(capacity: totalCount)
        }
    }

    /// Resize the sorter's capacity and create a new buffer pool.
    ///
    /// The old pool continues to exist and drains naturally as in-flight buffers
    /// are released via GPU completion handlers.
    private func resize(capacity newCapacity: Int) {
        capacity = newCapacity
        sorter.grow(capacity: newCapacity)
        _indexBufferPool = Self.makeIndexBufferPool(device: device, capacity: newCapacity, preallocatedCount: 0)
    }

    /// Create a new index buffer pool with the given capacity.
    private static func makeIndexBufferPool(device: MTLDevice, capacity: Int, preallocatedCount: Int) -> Pool<TypedMTLBuffer<IndexedDistance>> {
        Pool<TypedMTLBuffer<IndexedDistance>>(preallocatedCount: preallocatedCount) { id in
            let buffer = device.makeBuffer(length: capacity * MemoryLayout<IndexedDistance>.stride, options: [])!
            buffer.label = "IndexBuffer-pool-\(id)"
            return TypedMTLBuffer<IndexedDistance>(buffer: buffer, count: 0)
        }
    }

    /// Convenience for switching to a single splat cloud.
    ///
    /// Equivalent to `setSplatClouds([cloud])`. See ``setSplatClouds(_:)`` for details.
    public func setSplatCloud(_ cloud: GPUSplatCloud<Splat>) {
        setSplatClouds([cloud])
    }

    /// Request an async sort with the given parameters
    nonisolated
    public func requestSort(_ parameters: SortParameters) {
        _sortRequestStream.yield(parameters)
    }

    /// Perform a synchronous sort immediately and return the result (nonisolated wrapper).
    /// Blocks the calling thread until the sort completes.
    nonisolated
    public func sortNowSync(_ parameters: SortParameters) -> SplatIndices {
        let done = Atomic<Bool>(false)
        let result = Mutex<SplatIndices?>(nil)

        Task { [self] in
            let sorted = await self.sortNowAsync(parameters)
            result.withLock { $0 = sorted }
            done.store(true, ordering: .releasing)
        }

        // Spin wait (not ideal but simple)
        while !done.load(ordering: .acquiring) {
            Thread.sleep(forTimeInterval: 0.0001)
        }

        return result.withLock { $0! }
    }

    /// Performs an async sort immediately and returns the result.
    ///
    /// Also updates ``isSorted``, ``currentSortedIndices``, and yields to
    /// ``sortedIndicesStream`` and ``sortEventStream``.
    public func sortNowAsync(_ parameters: SortParameters) -> SplatIndices {
        assertNotMainThread("sortNowAsync")
        let start = CFAbsoluteTimeGetCurrent()
        var outputBuffer = _indexBufferPool.acquire()
        let totalSplats: Int

        if splatClouds.count == 1 {
            let cloud = splatClouds[0]
            let combinedModel = parameters.model * cloud.modelTransform
            sorter.sort(splats: cloud.splats, into: &outputBuffer, camera: parameters.camera, model: combinedModel, reversed: parameters.reversed)
            totalSplats = cloud.splats.count
        } else {
            sorter.sort(clouds: splatClouds, into: &outputBuffer, camera: parameters.camera, sceneModel: parameters.model, reversed: parameters.reversed)
            totalSplats = splatClouds.reduce(0) { $0 + $1.splats.count }
        }

        let end = CFAbsoluteTimeGetCurrent()
        let duration = end - start

        let result = SplatIndices(parameters: parameters, indices: outputBuffer)
        currentSortedIndices = result
        isSorted = true

        let event = SortEvent(time: Date(), duration: duration, splatCount: totalSplats, cloudCount: splatClouds.count)
        _sortEventStream.yield(event)
        _sortedIndicesStream.yield(result)

        return result
    }

    /// Process a single sort request
    private func processSortRequest(_ parameters: SortParameters, logger: Logger?) throws {
        try Task.checkCancellation()
        assertNotMainThread("processSortRequest")
        let start = CFAbsoluteTimeGetCurrent()
        var outputBuffer = _indexBufferPool.acquire()
        let totalSplats: Int
        if splatClouds.count == 1 {
            // Single cloud path - combine scene model with cloud transform
            let cloud = splatClouds[0]
            let combinedModel = parameters.model * cloud.modelTransform
            sorter.sort(splats: cloud.splats, into: &outputBuffer, camera: parameters.camera, model: combinedModel, reversed: parameters.reversed)
            totalSplats = cloud.splats.count
        } else {
            // Multi-cloud path - sorter handles per-cloud transforms internally
            sorter.sort(clouds: splatClouds, into: &outputBuffer, camera: parameters.camera, sceneModel: parameters.model, reversed: parameters.reversed)
            totalSplats = splatClouds.reduce(0) { $0 + $1.splats.count }
        }
        let end = CFAbsoluteTimeGetCurrent()
        let duration = end - start
        if duration > 0.033 {
            logger?.warning("### Sort took longer than expected (\(duration * 1_000) msec, \(duration / 0.033)x).")
        }

        let result = SplatIndices(parameters: parameters, indices: outputBuffer)
        currentSortedIndices = result
        isSorted = true

        let event = SortEvent(time: Date(), duration: duration, splatCount: totalSplats, cloudCount: splatClouds.count)
        _sortEventStream.yield(event)
        _sortedIndicesStream.yield(result)
    }
}
#endif
