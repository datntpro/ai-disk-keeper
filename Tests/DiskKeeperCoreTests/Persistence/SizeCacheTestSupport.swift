import Darwin
import Foundation
@testable import DiskKeeperCore

/// A journal the test controls.
final class FakeJournal: FSEventsJournaling, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: JournalResult = .changed([])
    private var _uuid: String? = "UUID-A"
    private var _id: UInt64 = 100
    private(set) var sinceRequests: [UInt64] = []

    var result: JournalResult { get { lock.withLock { _result } } set { lock.withLock { _result = newValue } } }
    var uuid: String? { get { lock.withLock { _uuid } } set { lock.withLock { _uuid = newValue } } }
    var id: UInt64 { get { lock.withLock { _id } } set { lock.withLock { _id = newValue } } }

    func currentEventID() -> UInt64 { id }
    func volumeUUID(device: dev_t) -> String? { uuid }
    func changedPaths(since eventID: UInt64, device: dev_t) async -> JournalResult {
        lock.withLock { sinceRequests.append(eventID) }
        return result
    }
}

func makeContext(_ fx: FixtureHome, cache: SizeCache?, now: Date = Date()) throws -> ScanContext {
    ScanContext(environment: fx.env, pathGuard: try ScanGuard(environment: fx.env, protectPatterns: []),
                now: now, maxConcurrentSizing: 4, sizeCache: cache)
}
