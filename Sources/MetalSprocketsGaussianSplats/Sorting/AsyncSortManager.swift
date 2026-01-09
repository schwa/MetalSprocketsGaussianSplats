#if !arch(x86_64)
internal import AsyncAlgorithms
@preconcurrency import Metal
import MetalSprocketsGaussianSplatShaders
internal import os
import simd
import Splats

internal actor AsyncSortManager <Splat> where Splat: SortableSplatProtocol {
    private var splatClouds: [GPUSplatCloud<Splat>]
    private var _sortRequestChannel: AsyncChannel<SortParameters> = .init()
    private var _sortedIndicesChannel: AsyncChannel<SplatIndices> = .init()
    private var logger: Logger?
    private var sorter: CPUSplatRadixSorter<Splat>

    /// Initialize with multiple clouds
    internal init(device: MTLDevice, splatClouds: [GPUSplatCloud<Splat>], capacity: Int, logger: Logger? = nil) throws {
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
    internal init(device: MTLDevice, splatCloud: GPUSplatCloud<Splat>, capacity: Int, logger: Logger? = nil) throws {
        try self.init(device: device, splatClouds: [splatCloud], capacity: capacity, logger: logger)
    }

    internal func sortedIndicesChannel() -> AsyncChannel<SplatIndices> {
        _sortedIndicesChannel
    }

    nonisolated
    internal func requestSort(_ parameters: SortParameters) {
        Task {
            await _sortRequestChannel.send(parameters)
        }
    }

    private func startSorting() async throws {
        let channel = _sortRequestChannel.removeDuplicates { lhs, rhs in
            lhs == rhs
        }
        ._throttle(for: .milliseconds(33.3333))

        for await parameters in channel {
            let start = CFAbsoluteTimeGetCurrent()
            let currentIndexedDistances: TypedMTLBuffer<IndexedDistance>
            if splatClouds.count == 1 {
                // Single cloud path - combine scene model with cloud transform
                let cloud = splatClouds[0]
                let combinedModel = parameters.model * cloud.modelTransform
                currentIndexedDistances = try sorter.sort(splats: cloud.splats, camera: parameters.camera, model: combinedModel, reversed: parameters.reversed)
            } else {
                // Multi-cloud path - sorter handles per-cloud transforms internally
                currentIndexedDistances = try sorter.sort(clouds: splatClouds, camera: parameters.camera, sceneModel: parameters.model, reversed: parameters.reversed)
            }
            let end = CFAbsoluteTimeGetCurrent()
            let duration = end - start
            if duration > 0.033 {
                logger?.warning("### Sort took longer than expected (\(duration * 1_000) msec, \(duration / 0.033)x).")
            }
            await self._sortedIndicesChannel.send(.init(parameters: parameters, indices: currentIndexedDistances))
        }
    }
}
#endif
