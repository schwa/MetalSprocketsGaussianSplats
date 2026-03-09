#if !arch(x86_64)
public import AsyncAlgorithms
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
    private var _sortRequestChannel: AsyncChannel<SortParameters> = .init()
    private var _sortedIndicesChannel: AsyncChannel<SplatIndices> = .init()
    private var _sortEventChannel: AsyncChannel<SortEvent> = .init()
    private var logger: Logger?
    private var sorter: CPUSplatRadixSorter<Splat>

    /// Whether at least one sort has completed
    public private(set) var isSorted: Bool = false

    /// The most recent sorted indices (nil until first sort completes)
    public private(set) var currentSortedIndices: SplatIndices?

    /// Initialize with multiple clouds
    public init(device: MTLDevice, splatClouds: [GPUSplatCloud<Splat>], capacity: Int) throws {
        self.sorter = .init(device: device, capacity: capacity)
        self.splatClouds = splatClouds
        self.logger = nil
        Task(priority: .high) {
            do {
                try await self.startSorting()
            } catch is CancellationError {
                // This line intentionally left blank.
            } catch {
                // Silently fail - no logger
            }
        }
    }

    /// Internal initializer with logger support
    internal init(device: MTLDevice, splatClouds: [GPUSplatCloud<Splat>], capacity: Int, logger: Logger?) throws {
        self.sorter = .init(device: device, capacity: capacity)
        self.splatClouds = splatClouds
        self.logger = logger
        Task(priority: .high) {
            do {
                try await self.startSorting()
            } catch is CancellationError {
                // This line intentionally left blank.
            } catch {
                logger?.log("Failed to sort splats: \(error)")
            }
        }
    }

    /// Convenience initializer for single cloud
    public init(device: MTLDevice, splatCloud: GPUSplatCloud<Splat>, capacity: Int) throws {
        try self.init(device: device, splatClouds: [splatCloud], capacity: capacity)
    }

    public func sortedIndicesChannel() -> AsyncChannel<SplatIndices> {
        _sortedIndicesChannel
    }

    public func sortEventChannel() -> AsyncChannel<SortEvent> {
        _sortEventChannel
    }

    /// Request an async sort with the given parameters
    nonisolated
    public func requestSort(_ parameters: SortParameters) {
        Task {
            await _sortRequestChannel.send(parameters)
        }
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

        // Send to channels (fire and forget)
        // Fire-and-forget send to avoid blocking on channel back-pressure
        let event = SortEvent(time: Date(), duration: duration, splatCount: totalSplats, cloudCount: splatClouds.count)
        Task {
            await _sortEventChannel.send(event)
        }
        Task {
            await _sortedIndicesChannel.send(result)
        }

        return result
    }

    private func startSorting() async throws {
        let channel = _sortRequestChannel.removeDuplicates { lhs, rhs in
            lhs == rhs
        }
        ._throttle(for: .milliseconds(33.3333))

        for await parameters in channel {
            assertNotMainThread("startSorting")
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

            // Fire-and-forget send to avoid blocking on channel back-pressure
            let event = SortEvent(time: Date(), duration: duration, splatCount: totalSplats, cloudCount: splatClouds.count)
            Task {
                await _sortEventChannel.send(event)
            }
            Task {
                await _sortedIndicesChannel.send(result)
            }
        }
    }
}
#endif
