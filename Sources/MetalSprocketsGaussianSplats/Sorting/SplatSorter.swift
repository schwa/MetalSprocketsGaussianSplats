#if !arch(x86_64)

import Metal
import MetalSprocketsGaussianSplatShaders
import simd
import Splats

/// A lightweight one-shot sorter for Gaussian splat clouds.
///
/// `SplatSorter` is intended for offline or single-frame contexts — snapshot rendering,
/// tests, CLI tools — where the full ``AsyncSortManager`` is unnecessary overhead.
/// It performs a synchronous, blocking sort and returns ``SplatIndices`` directly.
///
/// For continuous interactive rendering, use ``AsyncSortManager`` instead.
///
/// > Note: ``SplatIndices`` returned by `SplatSorter` are not pool-managed.
/// > Calling ``SplatIndices/release()`` on them is a no-op. The underlying
/// > buffer will be deallocated normally when the ``SplatIndices`` value is discarded.
///
/// ## Usage
///
/// ```swift
/// // Single cloud
/// let indices = try SplatSorter.sort(device: device, splatCloud: cloud, parameters: params)
///
/// // Multiple clouds
/// let indices = try SplatSorter.sort(device: device, splatClouds: clouds, parameters: params)
/// ```
public enum SplatSorter {
    /// Sort a single splat cloud and return the sorted indices.
    ///
    /// - Parameters:
    ///   - device: The Metal device to use for buffer allocation.
    ///   - splatCloud: The splat cloud to sort.
    ///   - parameters: Sort parameters (camera, model matrix, sort order).
    /// - Returns: Sorted ``SplatIndices`` ready for use with a render pipeline.
    public static func sort<Splat: SortableSplatProtocol>(
        device: MTLDevice,
        splatCloud: GPUSplatCloud<Splat>,
        parameters: SortParameters
    ) throws -> SplatIndices {
        let combinedModel = parameters.model * splatCloud.modelTransform
        return try CPUSplatRadixSorter.sort(
            device: device,
            splats: splatCloud.splats,
            camera: parameters.camera,
            model: combinedModel,
            reversed: parameters.reversed
        )
    }

    /// Sort multiple splat clouds together and return unified sorted indices.
    ///
    /// All clouds are sorted into a single ``SplatIndices`` result, with each entry
    /// carrying a `cloudIndex` identifying its source cloud.
    ///
    /// If `splatClouds` is empty, returns a ``SplatIndices`` with zero indices.
    ///
    /// - Parameters:
    ///   - device: The Metal device to use for buffer allocation.
    ///   - splatClouds: The splat clouds to sort together.
    ///   - parameters: Sort parameters (camera, scene model matrix, sort order).
    /// - Returns: Unified sorted ``SplatIndices`` ready for use with a render pipeline.
    public static func sort<Splat: SortableSplatProtocol>(
        device: MTLDevice,
        splatClouds: [GPUSplatCloud<Splat>],
        parameters: SortParameters
    ) throws -> SplatIndices {
        let totalCount = splatClouds.reduce(0) { $0 + $1.count }
        guard totalCount > 0 else {
            var emptyBuffer = try device.makeTypedBuffer(element: IndexedDistance.self, capacity: 1, options: []).labeled("IndexBuffer-empty")
            emptyBuffer.count = 0
            return SplatIndices(parameters: parameters, indices: emptyBuffer)
        }
        return try CPUSplatRadixSorter.sort(
            device: device,
            clouds: splatClouds,
            camera: parameters.camera,
            sceneModel: parameters.model,
            reversed: parameters.reversed
        )
    }
}

#endif
