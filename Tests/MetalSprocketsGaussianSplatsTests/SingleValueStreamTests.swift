import XCTest
@testable import MetalSprocketsGaussianSplats

// MARK: - Initialization

final class InitializationTests: XCTestCase {
    func testCurrentValueIsNilOnInit() {
        let stream = SingleValueStream<Int>()
        XCTAssertNil(stream.currentValue)
    }
}

// MARK: - currentValue

final class CurrentValueTests: XCTestCase {
    func testCurrentValueUpdatesAfterYield() {
        let stream = SingleValueStream<Int>()
        stream.yield(42)
        XCTAssertEqual(stream.currentValue, 42)
    }

    func testCurrentValueReflectsLatestYield() {
        let stream = SingleValueStream<Int>()
        stream.yield(1)
        stream.yield(2)
        stream.yield(3)
        XCTAssertEqual(stream.currentValue, 3)
    }

    func testCurrentValueWorksWithOptionalElement() {
        let stream = SingleValueStream<Int?>()
        stream.yield(nil)
        // currentValue is Optional<Optional<Int>>, outer is .some, inner is nil
        XCTAssertEqual(stream.currentValue, Optional<Int?>.some(nil))
    }

    func testCurrentValuePersistsAfterFinish() {
        let stream = SingleValueStream<Int>()
        stream.yield(99)
        stream.finish()
        XCTAssertEqual(stream.currentValue, 99)
    }

    func testCurrentValueUpdatesAfterManyYields() {
        let stream = SingleValueStream<Int>()
        for i in 0..<1000 {
            stream.yield(i)
        }
        XCTAssertEqual(stream.currentValue, 999)
    }
}

// MARK: - yield and consume

final class YieldAndConsumeTests: XCTestCase {
    func testSingleYieldSingleConsume() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        stream.yield(42)
        let result = await task.value
        XCTAssertEqual(result, 42)
        stream.finish()
    }

    func testMultipleYieldsConsumedInOrder() async {
        let stream = SingleValueStream<String>()

        let task = Task {
            var results: [String] = []
            for await value in stream {
                results.append(value)
            }
            return results
        }

        stream.yield("a")
        try? await Task.sleep(for: .milliseconds(10))
        stream.yield("b")
        try? await Task.sleep(for: .milliseconds(10))
        stream.yield("c")
        try? await Task.sleep(for: .milliseconds(10))

        stream.finish()
        let collected = await task.value
        XCTAssertEqual(collected, ["a", "b", "c"])
    }

    func testYieldBeforeConsumerStarts() async {
        let stream = SingleValueStream<Int>()

        // Yield before any consumer exists — buffered
        stream.yield(42)

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let result = await task.value
        XCTAssertEqual(result, 42)
        stream.finish()
    }

    func testYieldAfterFinishIsIgnored() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var results: [Int] = []
            for await value in stream {
                results.append(value)
            }
            return results
        }

        stream.yield(1)
        try? await Task.sleep(for: .milliseconds(10))
        stream.finish()
        stream.yield(2)
        stream.yield(3)

        let results = await task.value
        XCTAssertEqual(results, [1])
    }
}

// MARK: - finish

final class FinishTests: XCTestCase {
    func testFinishTerminatesConsumer() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var results: [Int] = []
            for await value in stream {
                results.append(value)
            }
            return results
        }

        stream.finish()
        let results = await task.value
        XCTAssert(results.isEmpty)
    }

    func testDoubleFinishDoesNotCrash() {
        let stream = SingleValueStream<Int>()
        stream.finish()
        stream.finish()
    }

    func testFinishAfterManyYields() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        for i in 0..<100 {
            stream.yield(i)
        }
        stream.finish()

        let count = await task.value
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testIteratorReturnsNilAfterFinish() async {
        let stream = SingleValueStream<Int>()
        stream.finish()

        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertNil(value)
    }
}

// MARK: - Buffering (only latest kept)

final class BufferingTests: XCTestCase {
    func testRapidYieldsDropOldValues() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var results: [Int] = []
            for await value in stream {
                results.append(value)
                try? await Task.sleep(for: .milliseconds(50))
            }
            return results
        }

        try? await Task.sleep(for: .milliseconds(10))

        for i in 0..<20 {
            stream.yield(i)
        }

        try? await Task.sleep(for: .milliseconds(200))
        stream.finish()

        let results = await task.value
        XCTAssertLessThan(results.count, 20)
        XCTAssertGreaterThanOrEqual(results.last!, 10)
    }

    func testBufferHoldsOneValueWhenConsumerIsSlow() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var results: [Int] = []
            for await value in stream {
                results.append(value)
                try? await Task.sleep(for: .milliseconds(100))
            }
            return results
        }

        try? await Task.sleep(for: .milliseconds(10))

        stream.yield(1)
        stream.yield(2)
        stream.yield(3)

        try? await Task.sleep(for: .milliseconds(250))
        stream.finish()

        let results = await task.value
        XCTAssertLessThanOrEqual(results.count, 3)
    }
}

// MARK: - Consumer lifecycle

final class ConsumerLifecycleTests: XCTestCase {
    func testConsumerBreaksEarly() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 2 {
                    break
                }
            }
            return count
        }

        stream.yield(1)
        try? await Task.sleep(for: .milliseconds(10))
        stream.yield(2)
        try? await Task.sleep(for: .milliseconds(10))

        let count = await task.value
        XCTAssertEqual(count, 2)

        // Yielding after consumer left should not block or crash
        stream.yield(3)
        stream.yield(4)
        stream.finish()
    }

    func testYieldAfterConsumerGoneDoesNotBlock() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        stream.yield(1)
        await task.value

        let start = ContinuousClock.now
        for i in 2..<1000 {
            stream.yield(i)
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(100))
        stream.finish()
    }

    func testTaskCancellationStopsConsumer() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            for await _ in stream {
                // consumed
            }
        }

        task.cancel()
        stream.yield(1)
        try? await Task.sleep(for: .milliseconds(50))

        await task.value
        stream.finish()
    }
}

// MARK: - for await iteration

final class ForAwaitTests: XCTestCase {
    func testForAwaitReceivesValues() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var results: [Int] = []
            for await value in stream {
                results.append(value)
            }
            return results
        }

        stream.yield(10)
        try? await Task.sleep(for: .milliseconds(10))
        stream.yield(20)
        try? await Task.sleep(for: .milliseconds(10))
        stream.finish()

        let results = await task.value
        XCTAssertEqual(results, [10, 20])
    }

    func testForAwaitExitsOnFinish() async {
        let stream = SingleValueStream<Int>()
        let expectation = XCTestExpectation(description: "loop exited")

        let task = Task {
            for await _ in stream {}
            expectation.fulfill()
        }

        stream.finish()
        await task.value
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testForAwaitOnEmptyFinishedStream() async {
        let stream = SingleValueStream<Int>()
        stream.finish()

        let task = Task {
            var results: [Int] = []
            for await value in stream {
                results.append(value)
            }
            return results
        }

        let results = await task.value
        XCTAssert(results.isEmpty)
    }
}

// MARK: - Concurrency safety

final class ConcurrencySafetyTests: XCTestCase {
    func testConcurrentYieldsDoNotCrash() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    stream.yield(i)
                }
            }
        }

        stream.finish()
        let count = await task.value
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testCurrentValueIsConsistentUnderConcurrentYields() async {
        let stream = SingleValueStream<Int>()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    stream.yield(i)
                }
            }
        }

        let value = stream.currentValue!
        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThan(value, 1000)
        stream.finish()
    }

    func testYieldAndReadCurrentValueConcurrently() async {
        let stream = SingleValueStream<Int>()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<1000 {
                    stream.yield(i)
                }
            }
            group.addTask {
                for _ in 0..<1000 {
                    _ = stream.currentValue
                }
            }
        }

        stream.finish()
    }
}

// MARK: - Edge cases

final class EdgeCaseTests: XCTestCase {
    func testYieldWithNoConsumerAndNoFinish() {
        let stream = SingleValueStream<Int>()
        stream.yield(1)
        stream.yield(2)
        stream.yield(3)
        // deinit should call finish — no leak or crash
    }

    func testYieldLargeValue() {
        let stream = SingleValueStream<[Int]>()
        let bigArray = Array(0..<100_000)
        stream.yield(bigArray)
        XCTAssertEqual(stream.currentValue?.count, 100_000)
        stream.finish()
    }

    func testMultipleFinishesWithConsumer() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var results: [Int] = []
            for await value in stream {
                results.append(value)
            }
            return results
        }

        stream.yield(1)
        try? await Task.sleep(for: .milliseconds(10))
        stream.finish()
        stream.finish()
        stream.finish()

        let results = await task.value
        XCTAssertEqual(results, [1])
    }
}

// MARK: - Actor integration

final class ActorIntegrationTests: XCTestCase {
    actor Counter {
        private let stream = SingleValueStream<Int>()
        private var count = 0

        var values: SingleValueStream<Int> { stream }

        func increment() {
            count += 1
            stream.yield(count)
        }

        func stop() {
            stream.finish()
        }
    }

    func testActorYieldsToExternalConsumer() async {
        let counter = Counter()

        let task = Task {
            var results: [Int] = []
            for await value in await counter.values {
                results.append(value)
            }
            return results
        }

        await counter.increment()
        try? await Task.sleep(for: .milliseconds(10))
        await counter.increment()
        try? await Task.sleep(for: .milliseconds(10))
        await counter.increment()
        try? await Task.sleep(for: .milliseconds(10))

        await counter.stop()
        let results = await task.value
        XCTAssertEqual(results, [1, 2, 3])
    }

    func testActorShutdownFinishesStream() async {
        let counter = Counter()

        let task = Task {
            var count = 0
            for await _ in await counter.values {
                count += 1
            }
            return count
        }

        await counter.increment()
        try? await Task.sleep(for: .milliseconds(10))
        await counter.stop()

        let count = await task.value
        XCTAssertEqual(count, 1)
    }
}

// MARK: - Timeout safety (no hangs)

final class TimeoutTests: XCTestCase {
    func testFinishUnblocksConsumer() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            for await _ in stream {}
        }

        try? await Task.sleep(for: .milliseconds(100))
        stream.finish()
        await task.value
    }

    func testYieldAfterConsumerGoneDoesNotHang() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        stream.yield(1)
        await task.value

        for i in 0..<10_000 {
            stream.yield(i)
        }
        stream.finish()
    }

    func testEmptyStreamFinishDoesNotHang() async {
        let stream = SingleValueStream<Int>()

        let task = Task {
            for await _ in stream {}
        }

        stream.finish()
        await task.value
    }
}
