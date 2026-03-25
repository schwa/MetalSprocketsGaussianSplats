#if !arch(x86_64)

@preconcurrency import Metal
import MetalSprocketsGaussianSplatShaders
internal import os
import simd
import Splats

private let signposter: OSSignposter = .init(subsystem: "io.schwa.MetalSprockets-examples", category: OSLog.Category.pointsOfInterest)

internal class CPUSplatRadixSorter <Splat> where Splat: SortableSplatProtocol {
    private var device: MTLDevice
    private var temporaryIndexedDistances: [IndexedDistance]
    private var capacity: Int
    private var signpost = signposter.makeSignpostID()

    internal init(device: MTLDevice, capacity: Int) {
        self.device = device
        self.capacity = capacity
        releaseAssert(capacity > 0, "You shouldn't be creating a sorter with a capacity of zero.")
        temporaryIndexedDistances = .init(repeating: .init(), count: capacity)
    }

    /// Sort a single cloud's splats
    internal func sort(splats: TypedMTLBuffer<Splat>, camera: simd_float4x4, model: simd_float4x4, reversed: Bool = false) throws -> TypedMTLBuffer<IndexedDistance> {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let durationMS = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
            if durationMS > 16 {
                logger?.warning("CPU splat sort: \(durationMS.formatted(.number.precision(.fractionLength(2))))ms (\(splats.count) splats)")
            }
        }
        return try signposter.withIntervalSignpost("CPUSplatRadixSorter.sort().make_buffers", id: signpost) {
            var currentIndexedDistances = try signposter.withIntervalSignpost("CPUSplatRadixSorter.sort()", id: signpost) {
                try device.makeTypedBuffer(element: IndexedDistance.self, capacity: capacity, options: []).labeled("\(splats.unsafeMTLBuffer.label ?? "splats")-indexed_distances-\(Date.now.iso8601)")
            }
            signposter.withIntervalSignpost("CPUSplatRadixSorter.cpuRadixSort()", id: signpost) {
                cpuRadixSort(splats: splats, indexedDistances: &currentIndexedDistances, temporaryIndexedDistances: &temporaryIndexedDistances, camera: camera, model: model, reversed: reversed)
            }
            // Update count after sorting - the buffer now contains splats.count sorted indices
            currentIndexedDistances.count = splats.count
            return currentIndexedDistances
        }
    }

    /// Sort multiple clouds' splats together into a unified sorted buffer
    /// - Parameters:
    ///   - clouds: Array of splat clouds (each with its own modelTransform)
    ///   - camera: Camera matrix
    ///   - sceneModel: Scene-level model matrix (applied to all clouds)
    ///   - reversed: Whether to reverse sort order
    /// - Returns: Unified sorted IndexedDistance buffer with cloudIndex populated
    internal func sort(clouds: [GPUSplatCloud<Splat>], camera: simd_float4x4, sceneModel: simd_float4x4, reversed: Bool = false) throws -> TypedMTLBuffer<IndexedDistance> {
        let totalCount = clouds.reduce(0) { $0 + $1.count }
        releaseAssert(totalCount <= capacity, "Total splat count \(totalCount) exceeds capacity \(capacity)")

        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let durationMS = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
            if durationMS > 16 {
                logger?.warning("CPU multi-cloud splat sort: \(durationMS.formatted(.number.precision(.fractionLength(2))))ms (\(totalCount) splats across \(clouds.count) clouds)")
            }
        }

        return try signposter.withIntervalSignpost("CPUSplatRadixSorter.sortMultiCloud()", id: signpost) {
            var currentIndexedDistances = try device.makeTypedBuffer(element: IndexedDistance.self, capacity: capacity, options: []).labeled("multi_cloud-indexed_distances-\(Date.now.iso8601)")

            signposter.withIntervalSignpost("CPUSplatRadixSorter.cpuRadixSortMultiCloud()", id: signpost) {
                cpuRadixSortMultiCloud(clouds: clouds, indexedDistances: &currentIndexedDistances, temporaryIndexedDistances: &temporaryIndexedDistances, camera: camera, sceneModel: sceneModel, reversed: reversed, totalCount: totalCount)
            }
            // Update count after sorting - the buffer now contains totalCount sorted indices
            currentIndexedDistances.count = totalCount
            return currentIndexedDistances
        }
    }
}

extension Date {
    var iso8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        formatter.formatOptions.remove(.withColonSeparatorInTime)
        formatter.formatOptions.remove(.withDashSeparatorInDate)
        return formatter.string(from: self)
    }
}

// MARK: -

// swiftlint:disable:next function_parameter_count
private func cpuRadixSort<Splat>(splats: TypedMTLBuffer<Splat>, indexedDistances: inout TypedMTLBuffer<IndexedDistance>, temporaryIndexedDistances: inout [IndexedDistance], camera: simd_float4x4, model: simd_float4x4, reversed: Bool) where Splat: SortableSplatProtocol {
    guard !splats.isEmpty else {
        return
    }
    releaseAssert(splats.count <= indexedDistances.capacity, "Too few indexed distances \(indexedDistances.count) for \(splats.capacity) splats.")
    releaseAssert(splats.count <= temporaryIndexedDistances.count, "Too few temporary indexed distances \(temporaryIndexedDistances.count) for \(splats.count) splats.")
    indexedDistances.withUnsafeMutableBufferPointer { indexedDistances in
        let indexedDistances = UnsafeMutableBufferPointer<IndexedDistance>(start: indexedDistances.baseAddress, count: splats.count)
        // Compute distances.
        let modelView = camera.inverse * model
        releaseAssert(splats.count <= indexedDistances.count, "Cannot sort \(splats.count) splats into \(indexedDistances.count) indexed distances.")
        splats.withUnsafeBufferPointer { splats in
            for index in 0..<splats.count {
                let position = modelView * SIMD4<Float>(splats[index].floatPosition, 1.0)
                let distance = position.z * (reversed ? -1.0 : 1.0)
                indexedDistances[index] = .init(splatIndex: UInt32(index), cloudIndex: 0, distanceToCamera: Float16(distance))
            }
        }
        temporaryIndexedDistances.withUnsafeMutableBufferPointer { temporaryIndexedDistances in
            let temporaryIndexedDistances = UnsafeMutableBufferPointer<IndexedDistance>(start: temporaryIndexedDistances.baseAddress, count: splats.count)
            releaseAssert(splats.count == indexedDistances.count, "Mismatch between splats \(splats.count) and indexed distances \(indexedDistances.count).")
            releaseAssert(splats.count == temporaryIndexedDistances.count, "Mismatch between splats \(splats.count) and temporary indexed distances \(temporaryIndexedDistances.count).")
            releaseAssert(temporaryIndexedDistances.count == indexedDistances.count, "Mismatch between temporary indexed distances \(temporaryIndexedDistances.count) and indexed distances \(indexedDistances.count).")
            RadixSortCPU<IndexedDistance>().radixSort(input: indexedDistances, temp: temporaryIndexedDistances)
        }
    }
}

// MARK: - Multi-Cloud Sort

// swiftlint:disable:next function_parameter_count
private func cpuRadixSortMultiCloud<Splat>(clouds: [GPUSplatCloud<Splat>], indexedDistances: inout TypedMTLBuffer<IndexedDistance>, temporaryIndexedDistances: inout [IndexedDistance], camera: simd_float4x4, sceneModel: simd_float4x4, reversed: Bool, totalCount: Int) where Splat: SortableSplatProtocol {
    guard totalCount > 0 else {
        return
    }
    releaseAssert(totalCount <= indexedDistances.capacity, "Too few indexed distances \(indexedDistances.capacity) for \(totalCount) splats.")
    releaseAssert(totalCount <= temporaryIndexedDistances.count, "Too few temporary indexed distances \(temporaryIndexedDistances.count) for \(totalCount) splats.")

    indexedDistances.withUnsafeMutableBufferPointer { indexedDistances in
        let indexedDistances = UnsafeMutableBufferPointer<IndexedDistance>(start: indexedDistances.baseAddress, count: totalCount)

        // Compute distances for all splats across all clouds
        var outputIndex = 0
        for (cloudIndex, cloud) in clouds.enumerated() {
            // Combine: view * sceneModel * cloudModelTransform
            let modelView = camera.inverse * sceneModel * cloud.modelTransform
            cloud.splats.withUnsafeBufferPointer { splats in
                for splatIndex in 0..<splats.count {
                    let position = modelView * SIMD4<Float>(splats[splatIndex].floatPosition, 1.0)
                    let distance = position.z * (reversed ? -1.0 : 1.0)
                    indexedDistances[outputIndex] = .init(splatIndex: UInt32(splatIndex), cloudIndex: UInt16(cloudIndex), distanceToCamera: Float16(distance))
                    outputIndex += 1
                }
            }
        }

        // Sort all indices together
        temporaryIndexedDistances.withUnsafeMutableBufferPointer { temporaryIndexedDistances in
            let temporaryIndexedDistances = UnsafeMutableBufferPointer<IndexedDistance>(start: temporaryIndexedDistances.baseAddress, count: totalCount)
            RadixSortCPU<IndexedDistance>().radixSort(input: indexedDistances, temp: temporaryIndexedDistances)
        }
    }
}

// MARK: -

extension IndexedDistance: RadixSortable {
    func key(shift: Int) -> Int {
        let bits = distanceToCamera.bitPattern
        let signMask: UInt16 = 0x8000
        let key: UInt16 = (bits & signMask != 0) ? ~bits : bits ^ signMask
        return (Int(key) >> shift) & 0xFF
    }

    static var totalKeyBitWidth: Int { 16 }
}

// MARK: -

extension IndexedDistance: @retroactive Equatable {
    public static func == (lhs: IndexedDistance, rhs: IndexedDistance) -> Bool {
        lhs.distanceToCamera == rhs.distanceToCamera
            && lhs.splatIndex == rhs.splatIndex
            && lhs.cloudIndex == rhs.cloudIndex
    }
}

extension IndexedDistance: @unchecked @retroactive Sendable {
}

internal func releaseAssert(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = String(), file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        fatalError(message(), file: file, line: line)
    }
}

internal extension CPUSplatRadixSorter {
    /// Convenience for single-cloud sort
    static func sort(device: MTLDevice, splats: TypedMTLBuffer<Splat>, camera: simd_float4x4, model: simd_float4x4, reversed: Bool) throws -> SplatIndices {
        let sorter = CPUSplatRadixSorter<Splat>(device: device, capacity: splats.count)
        let indices = try sorter.sort(splats: splats, camera: camera, model: model, reversed: reversed)
        return .init(parameters: .init(camera: camera, model: model, reversed: reversed), indices: indices)
    }

    /// Convenience for multi-cloud sort
    static func sort(device: MTLDevice, clouds: [GPUSplatCloud<Splat>], camera: simd_float4x4, sceneModel: simd_float4x4, reversed: Bool) throws -> SplatIndices {
        let totalCount = clouds.reduce(0) { $0 + $1.count }
        let sorter = CPUSplatRadixSorter<Splat>(device: device, capacity: totalCount)
        let indices = try sorter.sort(clouds: clouds, camera: camera, sceneModel: sceneModel, reversed: reversed)
        return .init(parameters: .init(camera: camera, model: sceneModel, reversed: reversed), indices: indices)
    }
}
#endif
