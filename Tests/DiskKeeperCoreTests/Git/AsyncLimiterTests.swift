import XCTest

@testable import DiskKeeperCore

final class AsyncLimiterTests: XCTestCase {
    actor Counter {
        var current = 0
        var maxSeen = 0
        var order: [Int] = []
        func enter() { current += 1; maxSeen = max(maxSeen, current) }
        func leave() { current -= 1 }
        func record(_ i: Int) { order.append(i) }
    }

    func testNeverExceedsLimit() async throws {
        let limiter = AsyncLimiter(limit: 3)
        let c = Counter()
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<20 {
                g.addTask {
                    try await limiter.acquire()
                    await c.enter()
                    try? await Task.sleep(for: .milliseconds(10))
                    await c.leave()
                    await limiter.release()
                }
            }
            try await g.waitForAll()
        }
        let m = await c.maxSeen
        XCTAssertLessThanOrEqual(m, 3)
        XCTAssertGreaterThan(m, 1)
    }

    func testCancelledWaiterDoesNotLeakSlot() async throws {
        let limiter = AsyncLimiter(limit: 1)
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        await limiter.release()
        // The slot must be free again.
        try await limiter.acquire()
        await limiter.release()
    }

    func testFIFO() async throws {
        let limiter = AsyncLimiter(limit: 1)
        let c = Counter()
        try await limiter.acquire()
        var tasks: [Task<Void, Error>] = []
        for i in 0..<5 {
            tasks.append(Task {
                try await limiter.acquire()
                await c.record(i)
                await limiter.release()
            })
            try await Task.sleep(for: .milliseconds(30))
        }
        await limiter.release()
        for t in tasks { try await t.value }
        let order = await c.order
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
    }
}
