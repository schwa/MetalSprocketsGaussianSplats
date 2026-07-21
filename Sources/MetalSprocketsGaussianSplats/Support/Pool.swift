internal import os
import Synchronization

/// A thread-safe generic object pool.
///
/// `Pool` manages reusable objects, reducing allocation overhead for frequently
/// created and discarded items. Objects are acquired from the pool and must be
/// explicitly released back when no longer needed.
///
/// ## Thread Safety
///
/// All operations are thread-safe via internal locking. Objects can be acquired
/// and released from any thread.
///
/// ## Typical Usage
///
/// ```swift
/// let pool = Pool<MTLBuffer>(preallocatedCount: 4) { id in
///     let buffer = device.makeBuffer(length: size)!
///     buffer.label = "PooledBuffer-\(id)"
///     return buffer
/// }
///
/// let buffer = pool.acquire()
/// // Use buffer...
/// commandBuffer.addCompletedHandler { _ in
///     pool.release(buffer)
/// }
/// ```
///
/// ## Pool Exhaustion
///
/// When all pooled objects are in use, `acquire()` allocates a new object using
/// the allocator closure and logs a warning. This helps identify when the
/// preallocated count is too low.
final class Pool<T: Sendable>: @unchecked Sendable {
    /// When true, `release()` is a no-op — objects are never returned to the pool.
    /// Useful for diagnosing buffer reuse issues (e.g. GPU still reading a released buffer).
    var releaseDisabled: Bool = false

    private let allocator: @Sendable (Int) -> T
    private let state: Mutex<State>

    private struct State {
        var available: [T] = []
        var nextID: Int = 0
    }

    /// Creates a new pool with the given allocator.
    ///
    /// - Parameters:
    ///   - preallocatedCount: Number of objects to create upfront. Default is 0.
    ///   - allocator: Closure that creates a new object. Receives an incrementing
    ///     ID that can be used for debug labeling.
    init(preallocatedCount: Int = 0, allocator: @escaping @Sendable (_ id: Int) -> T) {
        self.allocator = allocator
        var initialState = State()
        for id in 0..<preallocatedCount {
            initialState.available.append(allocator(id))
        }
        initialState.nextID = preallocatedCount
        self.state = Mutex(initialState)
    }

    /// Acquires an object from the pool.
    ///
    /// Returns a pooled object if available, otherwise allocates a new one.
    /// A warning is logged when allocation occurs due to pool exhaustion.
    ///
    /// - Returns: An object ready for use.
    func acquire() -> T {
        state.withLock { state in
            if let item = state.available.popLast() {
                return item
            }
            // Pool exhausted; allocate a fresh element.
            let id = state.nextID
            state.nextID += 1
            if !releaseDisabled {
                logger?.warning("Pool exhausted, allocating new object (id: \(id))")
            }
            return allocator(id)
        }
    }

    /// Releases an object back to the pool for reuse.
    ///
    /// Call this when the object is no longer in use. For GPU buffers, this
    /// should typically be done in a `commandBuffer.addCompletedHandler`.
    ///
    /// - Parameter item: The object to return to the pool.
    func release(_ item: T) {
        guard !releaseDisabled else {
            return
        }
        state.withLock { state in
            state.available.append(item)
        }
    }

    /// The number of objects currently available in the pool.
    ///
    /// Useful for debugging and monitoring pool utilization.
    var availableCount: Int {
        state.withLock { $0.available.count }
    }

    /// The total number of objects ever allocated by this pool.
    ///
    /// Includes both preallocated objects and those allocated on demand.
    var totalAllocatedCount: Int {
        state.withLock { $0.nextID }
    }
}
