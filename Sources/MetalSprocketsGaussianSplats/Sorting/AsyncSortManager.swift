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

public actor AsyncSortManager<Splat> where Splat: SortableSplatProtocol {
    private var splatClouds: [GPUSplatCloud<Splat>]
    private let _sortRequestStream = SingleValueStream<SortParameters>()
    private let _sortedIndicesStream = SingleValueStream<SplatIndices>()
    private let _sortEventStream = SingleValueStream<SortEvent>()
    private var logger: Logger?
    private var sorter: CPUSplatRadixSorter<Splat>
    nonisolated(unsafe) private var sortingTask: Task<Void, Never>?

    /// Whether at least one sort has completed
    public private(set) var isSorted: Bool = false

    /// The most recent sorted indices (nil until first sort completes)
    public private(set) var currentSortedIndices: SplatIndices?

    /// Initialize with multiple clouds
    public init(device: MTLDevice, splatClouds: [GPUSplatCloud<Splat>], capacity: Int) throws {
        self.sorter = .init(device: device, capacity: capacity)
        self.splatClouds = splatClouds
        self.logger = nil
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
    internal init(device: MTLDevice, splatClouds: [GPUSplatCloud<Splat>], capacity: Int, logger: Logger?) throws {
        self.sorter = .init(device: device, capacity: capacity)
        self.splatClouds = splatClouds
        self.logger = logger
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
    public init(device: MTLDevice, splatCloud: GPUSplatCloud<Splat>, capacity: Int) throws {
        try self.init(device: device, splatClouds: [splatCloud], capacity: capacity)
    }

    deinit {
        sortingTask?.cancel()
        _sortRequestStream.finish()
        _sortedIndicesStream.finish()
        _sortEventStream.finish()
    }

    public nonisolated var sortedIndicesStream: SingleValueStream<SplatIndices> {
        _sortedIndicesStream
    }

    public nonisolated var sortEventStream: SingleValueStream<SortEvent> {
        _sortEventStream
    }

    /// Request an async sort with the given parameters
    nonisolated
    public func requestSort(_ parameters: SortParameters) {
        _sortRequestStream.yield(parameters)
    }

    /// Perform a synchronous sort immediately and return the result (nonisolated wrapper).
    /// Blocks the calling thread until the sort completes.
    nonisolated
    public func sortNowSync(_ parameters: SortParameters) throws -> SplatIndices {
        let done = Atomic<Bool>(false)
        let result = Mutex<Result<SplatIndices, Error>?>(nil)

        Task { [self] in
            do {
                let sorted = try await self.sortNowAsync(parameters)
                result.withLock { $0 = .success(sorted) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            done.store(true, ordering: .releasing)
        }

        // Spin wait (not ideal but simple)
        while !done.load(ordering: .acquiring) {
            Thread.sleep(forTimeInterval: 0.0001)
        }

        return try result.withLock { $0! }.get()
    }

    /// Perform an async sort immediately and return the result.
    /// Also updates isSorted and currentSortedIndices, and sends to channels.
    public func sortNowAsync(_ parameters: SortParameters) throws -> SplatIndices {
        assertNotMainThread("sortNowAsync")
        let start = CFAbsoluteTimeGetCurrent()
        let currentIndexedDistances: TypedMTLBuffer<IndexedDistance>
        let totalSplats: Int

        if splatClouds.count == 1 {
            let cloud = splatClouds[0]
            let combinedModel = parameters.model * cloud.modelTransform
            currentIndexedDistances = try sorter.sort(splats: cloud.splats, camera: parameters.camera, model: combinedModel, reversed: parameters.reversed)
            totalSplats = cloud.splats.count
        } else {
            currentIndexedDistances = try sorter.sort(clouds: splatClouds, camera: parameters.camera, sceneModel: parameters.model, reversed: parameters.reversed)
            totalSplats = splatClouds.reduce(0) { $0 + $1.splats.count }
        }

        let end = CFAbsoluteTimeGetCurrent()
        let duration = end - start

        let result = SplatIndices(parameters: parameters, indices: currentIndexedDistances)
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
        let currentIndexedDistances: TypedMTLBuffer<IndexedDistance>
        let totalSplats: Int
        if splatClouds.count == 1 {
            // Single cloud path - combine scene model with cloud transform
            let cloud = splatClouds[0]
            let combinedModel = parameters.model * cloud.modelTransform
            currentIndexedDistances = try sorter.sort(splats: cloud.splats, camera: parameters.camera, model: combinedModel, reversed: parameters.reversed)
            totalSplats = cloud.splats.count
        } else {
            // Multi-cloud path - sorter handles per-cloud transforms internally
            currentIndexedDistances = try sorter.sort(clouds: splatClouds, camera: parameters.camera, sceneModel: parameters.model, reversed: parameters.reversed)
            totalSplats = splatClouds.reduce(0) { $0 + $1.splats.count }
        }
        let end = CFAbsoluteTimeGetCurrent()
        let duration = end - start
        if duration > 0.033 {
            logger?.warning("### Sort took longer than expected (\(duration * 1_000) msec, \(duration / 0.033)x).")
        }

        let result = SplatIndices(parameters: parameters, indices: currentIndexedDistances)
        currentSortedIndices = result
        isSorted = true

        let event = SortEvent(time: Date(), duration: duration, splatCount: totalSplats, cloudCount: splatClouds.count)
        _sortEventStream.yield(event)
        _sortedIndicesStream.yield(result)
    }
}
#endif
