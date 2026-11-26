import Foundation
import XCTest
@testable import DiskKeeperCore

final class DiskIndexerCancellationTests: XCTestCase {
    private static var fixture: FixtureHome?

    /// ≈ 200 k entries (2000 dirs × 100 files), built once for the class.
    override class func setUp() {
        super.setUp()
        guard let fx = try? FixtureHome() else { return }
        fixture = fx
        for d in 0..<2000 {
            let dir = fx.home + "/d\(d)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for f in 0..<100 { FileManager.default.createFile(atPath: dir + "/f\(f)", contents: nil) }
        }
    }

    override class func tearDown() { fixture = nil; super.tearDown() }

    private var slack: Double { Double(ProcessInfo.processInfo.environment["ADK_CI_SLACK"] ?? "") .map { min(max($0, 1), 3) } ?? 1 }

    func testCancelStopsWithin200ms() async throws {
        let fx = try XCTUnwrap(Self.fixture)
        var o = IndexOptions(); o.progressInterval = .zero
        let ix = try IndexTest.indexer(fx, options: o)
        let seen = Signal()
        let task = Task { try await ix.index(.home) { _ in seen.signal() } }
        try await seen.wait()
        let t0 = ContinuousClock.now
        await ix.cancel()
        do { _ = try await task.value; XCTFail("expected CancellationError") } catch is CancellationError {}
        XCTAssertLessThan(t0.duration(to: .now), .milliseconds(Int(200 * slack)))
    }

    func testTaskCancellationStopsWithin200ms() async throws {
        let fx = try XCTUnwrap(Self.fixture)
        var o = IndexOptions(); o.progressInterval = .zero
        let ix = try IndexTest.indexer(fx, options: o)
        let seen = Signal()
        let task = Task { try await ix.index(.home) { _ in seen.signal() } }
        try await seen.wait()
        let t0 = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("expected CancellationError") } catch is CancellationError {}
        XCTAssertLessThan(t0.duration(to: .now), .milliseconds(Int(200 * slack)))
    }

    func testIndexerReusableAfterCancel() async throws {
        let fx = try XCTUnwrap(Self.fixture)
        var o = IndexOptions(); o.progressInterval = .zero
        let ix = try IndexTest.indexer(fx, options: o)
        let seen = Signal()
        let task = Task { try await ix.index(.home) { _ in seen.signal() } }
        try await seen.wait()
        await ix.cancel()
        _ = try? await task.value
        let running = await ix.isRunning
        XCTAssertFalse(running)
        let tree = try await ix.index(.folder(fx.abs("d1")))
        XCTAssertEqual(tree.node(tree.root).fileCount, 100)
        let after = await ix.isRunning
        XCTAssertFalse(after)
    }
}

final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func signal() { lock.lock(); set = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
    func wait() async throws {
        while !isSet { try await Task.sleep(nanoseconds: 1_000_000) }
    }
}
