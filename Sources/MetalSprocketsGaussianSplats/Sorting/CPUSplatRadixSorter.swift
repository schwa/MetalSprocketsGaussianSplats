#if !arch(x86_64)

@preconcurrency import Metal
import MetalSprocketsGaussianSplatShaders
import MetalSprocketsSupport
internal import os
import simd
import Splats

private let signposter: OSSignposter = .init(subsystem: "io.schwa.MetalSprockets-examples", category: OSLog.Category.pointsOfInterest)

/// Whether to emit per-frame sort timing logs at info level. Controlled by the
/// `MSGS_SORT_LOG` environment variable, read once at process start. Default
/// off (logs are noisy at frame rate). Set to `1`, `true`, `yes`, or `on` to
/// enable. Slow-sort warnings (>16 ms) are always emitted regardless.
private let sortLoggingEnabled: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["MSGS_SORT_LOG"]?.lowercased() else {
        return false
    }
    switch raw {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}()

internal class CPUSplatRadixSorter <Splat> where Splat: SortableSplatProtocol {
    private var device: MTLDevice
    private var temporaryIndexedDistances: [IndexedDistance]
    internal private(set) var capacity: Int
    private var signpost = signposter.makeSignpostID()

    internal init(device: MTLDevice, capacity: Int) {
        self.device = device
        self.capacity = capacity
        releaseAssert(capacity > 0, "You shouldn't be creating a sorter with a capacity of zero.")
        temporaryIndexedDistances = .init(repeating: .init(), count: capacity)
    }

    /// Grow the sorter's scratch buffer to accommodate at least `newCapacity` splats.
    /// Has no effect if `newCapacity <= capacity`.
    internal func grow(capacity newCapacity: Int) {
        guard newCapacity > capacity else {
            return
        }
        capacity = newCapacity
        temporaryIndexedDistances = .init(repeating: .init(), count: newCapacity)
    }

    /// Sort a single cloud's splats into the provided buffer
    /// - Parameters:
    ///   - splats: The splats to sort
    ///   - outputBuffer: Buffer to write sorted indices into (must have capacity >= splats.count)
    ///   - camera: Camera matrix
    ///   - model: Model matrix
    ///   - reversed: Whether to reverse sort order
    internal func sort(splats: TypedMTLBuffer<Splat>, into outputBuffer: inout TypedMTLBuffer<IndexedDistance>, camera: simd_float4x4, model: simd_float4x4, reversed: Bool = false) {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let durationMS = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
            let line = "CPU splat sort: \(durationMS.formatted(.number.precision(.fractionLength(2))))ms (\(splats.count) splats)"
            if durationMS > 16 {
                logger?.warning("\(line)")
            } else if sortLoggingEnabled {
                logger?.info("\(line)")
            }
        }
        signposter.withIntervalSignpost("CPUSplatRadixSorter.sort()", id: signpost) {
            signposter.withIntervalSignpost("CPUSplatRadixSorter.cpuRadixSort()", id: signpost) {
                cpuRadixSort(splats: splats, indexedDistances: &outputBuffer, temporaryIndexedDistances: &temporaryIndexedDistances, camera: camera, model: model, reversed: reversed)
            }
            // Update count after sorting - the buffer now contains splats.count sorted indices
            outputBuffer.count = splats.count
        }
    }

    /// Sort multiple clouds' splats together into a unified sorted buffer
    /// - Parameters:
    ///   - clouds: Array of splat clouds (each with its own modelTransform)
    ///   - outputBuffer: Buffer to write sorted indices into
    ///   - camera: Camera matrix
    ///   - sceneModel: Scene-level model matrix (applied to all clouds)
    ///   - reversed: Whether to reverse sort order
    internal func sort(clouds: [GPUSplatCloud<Splat>], into outputBuffer: inout TypedMTLBuffer<IndexedDistance>, camera: simd_float4x4, sceneModel: simd_float4x4, reversed: Bool = false) {
        let totalCount = clouds.reduce(0) { $0 + $1.count }
        releaseAssert(totalCount <= capacity, "Total splat count \(totalCount) exceeds capacity \(capacity)")

        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let durationMS = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
            let line = "CPU multi-cloud splat sort: \(durationMS.formatted(.number.precision(.fractionLength(2))))ms (\(totalCount) splats across \(clouds.count) clouds)"
            if durationMS > 16 {
                logger?.warning("\(line)")
            } else if sortLoggingEnabled {
                logger?.info("\(line)")
            }
        }

        signposter.withIntervalSignpost("CPUSplatRadixSorter.sortMultiCloud()", id: signpost) {
            signposter.withIntervalSignpost("CPUSplatRadixSorter.cpuRadixSortMultiCloud()", id: signpost) {
                cpuRadixSortMultiCloud(clouds: clouds, indexedDistances: &outputBuffer, temporaryIndexedDistances: &temporaryIndexedDistances, camera: camera, sceneModel: sceneModel, reversed: reversed, totalCount: totalCount)
            }
            // Update count after sorting - the buffer now contains totalCount sorted indices
            outputBuffer.count = totalCount
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
    /// Convenience for single-cloud sort (allocates its own buffer)
    static func sort(device: MTLDevice, splats: TypedMTLBuffer<Splat>, camera: simd_float4x4, model: simd_float4x4, reversed: Bool) throws -> SplatIndices {
        let sorter = CPUSplatRadixSorter<Splat>(device: device, capacity: splats.count)
        let mtlBuffer = try device.makeBuffer(length: splats.count * MemoryLayout<IndexedDistance>.stride, options: []).orThrow(.resourceCreationFailure("Failed to create index buffer"))
        mtlBuffer.label = "IndexBuffer-oneshot"
        var outputBuffer = TypedMTLBuffer<IndexedDistance>(buffer: mtlBuffer, count: 0)
        sorter.sort(splats: splats, into: &outputBuffer, camera: camera, model: model, reversed: reversed)
        return .init(parameters: .init(camera: camera, model: model, reversed: reversed), indices: outputBuffer)
    }

    /// Convenience for multi-cloud sort (allocates its own buffer)
    static func sort(device: MTLDevice, clouds: [GPUSplatCloud<Splat>], camera: simd_float4x4, sceneModel: simd_float4x4, reversed: Bool) throws -> SplatIndices {
        let totalCount = clouds.reduce(0) { $0 + $1.count }
        let sorter = CPUSplatRadixSorter<Splat>(device: device, capacity: totalCount)
        let mtlBuffer = try device.makeBuffer(length: totalCount * MemoryLayout<IndexedDistance>.stride, options: []).orThrow(.resourceCreationFailure("Failed to create index buffer"))
        mtlBuffer.label = "IndexBuffer-oneshot"
        var outputBuffer = TypedMTLBuffer<IndexedDistance>(buffer: mtlBuffer, count: 0)
        sorter.sort(clouds: clouds, into: &outputBuffer, camera: camera, sceneModel: sceneModel, reversed: reversed)
        return .init(parameters: .init(camera: camera, model: sceneModel, reversed: reversed), indices: outputBuffer)
    }
}
#endif
