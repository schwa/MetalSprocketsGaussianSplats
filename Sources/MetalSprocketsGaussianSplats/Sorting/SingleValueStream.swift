import Foundation
internal import os

// MARK: - SingleValueStream

/// A non-blocking async sequence that only keeps the latest value.
///
/// `SingleValueStream` is designed for scenarios where only the most recent value matters,
/// such as streaming sorted indices where older sorts become stale immediately.
///
/// ## Why Not AsyncChannel?
///
/// `AsyncChannel.send()` blocks until a receiver consumes the value. When used with
/// fire-and-forget Tasks, this creates a leak if the receiver disappears:
///
/// ```swift
/// // PROBLEMATIC: Task blocks forever if receiver is gone
/// Task {
///     await channel.send(result)  // Blocks, holding MTLBuffer reference
/// }
/// ```
///
/// `SingleValueStream` uses `AsyncStream` with `.bufferingNewest(1)`, making `yield()`
/// non-blocking. Old values are dropped if not consumed - which is correct for "latest
/// value only" semantics.
///
/// ## Usage
///
/// **Producer:**
/// ```swift
/// let stream = SingleValueStream<SplatIndices>()
///
/// // Non-blocking - returns immediately
/// stream.yield(sortedIndices)
///
/// // Read latest without waiting
/// if let latest = stream.currentValue { ... }
///
/// // Clean shutdown
/// stream.finish()
/// ```
///
/// **Consumer:**
/// ```swift
/// for await indices in stream {
///     // Only receives values yielded after iteration starts
///     // May skip intermediate values if producer is faster
/// }
/// ```
///
/// ## Multiple Consumers
///
/// `SingleValueStream` supports multiple consumers, but with "last wins" semantics:
///
/// - All active iterators share the same underlying `AsyncStream`
/// - With `.bufferingNewest(1)`, only one value is buffered at a time
/// - Whichever consumer calls `next()` first gets the value
/// - Other consumers waiting will get the *next* yielded value (or none if producer is slower)
///
/// In practice, this means:
/// ```swift
/// // Task A starts iterating
/// for await value in stream { ... }
///
/// // Task A is cancelled, Task B starts iterating the SAME stream
/// for await value in stream { ... }  // Works fine - picks up where A left off
/// ```
///
/// This is ideal for SwiftUI's `.task` modifier which cancels and restarts on view cycles.
/// The new task seamlessly takes over from the cancelled one.
///
/// ## Thread Safety
///
/// - `yield(_:)` and `currentValue` are thread-safe
/// - Multiple concurrent consumers are supported (but values are not duplicated)
/// - Safe to yield from any thread/actor
///
/// ## When to Call `finish()`
///
/// **Usually you don't need to.** `finish()` is called automatically in `deinit`.
///
/// Call `finish()` explicitly when:
/// - You want to signal "no more values" before the object is deallocated
/// - You need consumers to exit their `for await` loops immediately
/// - You're implementing a shutdown sequence
///
/// After `finish()`:
/// - All active `for await` loops will complete (return `nil`)
/// - `yield()` calls are ignored
/// - `currentValue` retains the last yielded value
///
/// ## Memory Management
///
/// - No fire-and-forget Tasks means no retained references
/// - Safe for use in SwiftUI views that cycle (appear/disappear)
/// - When the owning object deinits, stream automatically finishes
///
public final class SingleValueStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias AsyncIterator = AsyncStream<Element>.AsyncIterator

    private let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation
    private let latestValue: OSAllocatedUnfairLock<Element?>

    /// The most recently yielded value, or `nil` if nothing has been yielded yet.
    public var currentValue: Element? {
        latestValue.withLock { $0 }
    }

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        self.latestValue = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Send a value to the stream. Non-blocking - returns immediately.
    /// If a previous value hasn't been consumed, it's dropped.
    /// Updates `currentValue`.
    public func yield(_ value: Element) {
        latestValue.withLock { $0 = value }
        continuation.yield(value)
    }

    /// Finish the stream. All pending iterations will complete.
    /// Also called automatically on deinit as a safety net.
    public func finish() {
        continuation.finish()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }

    deinit {
        continuation.finish()
    }
}
