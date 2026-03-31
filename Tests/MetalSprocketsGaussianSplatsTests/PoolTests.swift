@testable import MetalSprocketsGaussianSplats
import Testing

@Suite
struct PoolTests {
    @Test
    func acquireFromPreallocated() {
        let pool = Pool<Int>(preallocatedCount: 3) { id in
            id * 10
        }

        #expect(pool.availableCount == 3)
        #expect(pool.totalAllocatedCount == 3)

        let item1 = pool.acquire()
        #expect(item1 == 20) // Last item (LIFO)
        #expect(pool.availableCount == 2)

        let item2 = pool.acquire()
        #expect(item2 == 10)
        #expect(pool.availableCount == 1)

        let item3 = pool.acquire()
        #expect(item3 == 0)
        #expect(pool.availableCount == 0)
    }

    @Test
    func acquireAllocatesWhenExhausted() {
        let pool = Pool<Int>(preallocatedCount: 1) { id in
            id * 10
        }

        #expect(pool.totalAllocatedCount == 1)

        _ = pool.acquire() // Use preallocated
        #expect(pool.totalAllocatedCount == 1)

        _ = pool.acquire() // Should allocate new
        #expect(pool.totalAllocatedCount == 2)
    }

    @Test
    func releaseReturnsToPool() {
        let pool = Pool<Int>(preallocatedCount: 1) { id in id }

        let item = pool.acquire()
        #expect(pool.availableCount == 0)

        pool.release(item)
        #expect(pool.availableCount == 1)

        let reacquired = pool.acquire()
        #expect(reacquired == item)
        #expect(pool.availableCount == 0)
    }

    @Test
    func zeroPreallocation() {
        let pool = Pool<Int>(preallocatedCount: 0) { id in id }

        #expect(pool.availableCount == 0)
        #expect(pool.totalAllocatedCount == 0)

        let item = pool.acquire()
        #expect(item == 0)
        #expect(pool.totalAllocatedCount == 1)
    }

    @Test
    func threadSafety() async {
        let pool = Pool<Int>(preallocatedCount: 0) { id in id }

        // Spawn many concurrent acquires and releases
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let item = pool.acquire()
                    // Simulate some work
                    try? await Task.sleep(for: .microseconds(10))
                    pool.release(item)
                }
            }
        }

        // All items should be back in pool
        #expect(pool.availableCount == pool.totalAllocatedCount)
    }
}
