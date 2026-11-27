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

    /// Events the live watch will deliver on its next drain (nil entry = the watch lost events).
    private var _live: [String] = []
    private var _watchLost = false
    private var _noWatch = false
    var noWatch: Bool { get { lock.withLock { _noWatch } } set { lock.withLock { _noWatch = newValue } } }
    /// Simulates a write that happens (or is delivered) after the history query.
    func injectLive(_ paths: [String]) { lock.withLock { _live += paths } }
    func loseWatch() { lock.withLock { _watchLost = true } }
    func takeLive() -> [String]? {
        lock.withLock {
            if _watchLost { return nil }
            defer { _live = [] }
            return _live
        }
    }
    func openWatch(device: dev_t, since eventID: UInt64) -> (any JournalWatching)? {
        noWatch ? nil : FakeWatch(self)
    }

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

final class FakeWatch: JournalWatching, @unchecked Sendable {
    let owner: FakeJournal
    init(_ owner: FakeJournal) { self.owner = owner }
    func drain() -> [String]? { owner.takeLive() }
    func close() {}
}
