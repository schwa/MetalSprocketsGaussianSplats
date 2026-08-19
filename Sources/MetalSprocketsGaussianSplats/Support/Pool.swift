internal import os
import Synchronization

/// A thread-safe generic object pool.
///
/// `Pool` manages reusable objects. It reduces the allocation cost for items
/// that you create and discard often. Acquire an object from the pool. Release
/// it back when you no longer need it.
///
/// ## Thread Safety
///
/// Internal locking makes all operations thread-safe. You can acquire and
/// release objects from any thread.
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
/// If all pooled objects are in use, `acquire()` allocates a new object with
/// the allocator closure and logs a warning. The warning shows when the
/// preallocated count is too low.
final class Pool<T: Sendable>: @unchecked Sendable {
    /// When true, `release()` does nothing and objects never return to the pool.
    /// Use it to diagnose buffer reuse problems, such as a GPU that still reads
    /// a released buffer.
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
    ///   - allocator: Closure that creates a new object. It receives an
    ///     incrementing ID for debug labeling.
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
    /// Returns a pooled object if one is available. If none is available, it
    /// allocates a new one. Pool exhaustion logs a warning.
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
    /// Call this when the object is no longer in use. For GPU buffers, call it
    /// in a `commandBuffer.addCompletedHandler`.
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
    /// Use it to debug and monitor pool use.
    var availableCount: Int {
        state.withLock { $0.available.count }
    }

    /// The total number of objects this pool ever allocated.
    ///
    /// The total includes preallocated objects and objects allocated on demand.
    var totalAllocatedCount: Int {
        state.withLock { $0.nextID }
    }
}
