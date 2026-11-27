import CoreServices
import Darwin
import Foundation

/// What the file system journal says happened since an event id.
public enum JournalResult: Sendable, Equatable {
    /// Absolute paths that changed (files and directories; a path means "this path, or something inside it").
    case changed([String])
    /// The journal cannot vouch for anything (gap, drop, wrap, mount, timeout, UUID mismatch, …).
    case invalidateAll
}

/// Source of "what changed since" for the scan cache. A protocol so tests can fake gaps and drops.
public protocol FSEventsJournaling: Sendable {
    /// The id to remember BEFORE a scan starts (nothing that happens afterwards can be lost).
    func currentEventID() -> UInt64
    /// Identity of the volume's journal; a different value means the saved event ids mean nothing.
    func volumeUUID(device: dev_t) -> String?
    /// Everything that changed on `device` after `eventID`. Anything uncertain is `.invalidateAll`.
    func changedPaths(since eventID: UInt64, device: dev_t) async -> JournalResult
    /// A stream kept open for the whole scan, starting at `eventID`, so writes that happen (or are delivered late)
    /// after the history query are still seen. nil = cannot watch, so the cache must not be used for this scan.
    func openWatch(device: dev_t, since eventID: UInt64) -> (any JournalWatching)?
}

/// Live events of one scan.
public protocol JournalWatching: Sendable {
    /// Flushes what the daemon still holds, then returns the paths changed since the last call.
    /// nil = the watch can no longer vouch for anything (drops, wrap, overflow): drop every entry.
    func drain() -> [String]?
    func close()
}

/// Reads the persistent FSEvents history (`sinceWhen`) of one device. Read-only: it never writes to the volume.
public struct LiveFSEventsJournal: FSEventsJournaling {
    public var timeout: TimeInterval
    /// More events than this is not worth tracking: treated as "everything changed".
    public var maxEvents: Int

    public init(timeout: TimeInterval = 5, maxEvents: Int = 1_000_000) {
        self.timeout = timeout
        self.maxEvents = maxEvents
    }

    public func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    public func volumeUUID(device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device),
              let s = CFUUIDCreateString(nil, uuid) else { return nil }
        return s as String
    }

    public func changedPaths(since eventID: UInt64, device: dev_t) async -> JournalResult {
        let timeout = self.timeout
        let maxEvents = self.maxEvents
        return await withCheckedContinuation { (cont: CheckedContinuation<JournalResult, Never>) in
            let collector = Collector(maxEvents: maxEvents, continuation: cont)
            collector.start(device: device, since: eventID, timeout: timeout)
        }
    }

    /// Single-queue state machine: every access to its fields happens on `queue`.
    private final class Collector: @unchecked Sendable {
        let queue = DispatchQueue(label: "adk.fsevents-journal", qos: .utility)
        let maxEvents: Int
        var continuation: CheckedContinuation<JournalResult, Never>?
        var stream: FSEventStreamRef?
        var paths: [String] = []
        var poisoned = false
        var historyDone = false

        init(maxEvents: Int, continuation: CheckedContinuation<JournalResult, Never>) {
            self.maxEvents = maxEvents
            self.continuation = continuation
        }

        /// Flags after which the recorded paths cannot be trusted to be complete.
        static let untrusted: FSEventStreamEventFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

        func start(device: dev_t, since: UInt64, timeout: TimeInterval) {
            queue.async { [self] in
                var context = FSEventStreamContext(
                    version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                    copyDescription: nil)
                let flags = FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
                let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                    guard let info else { return }
                    let me = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
                    let list = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
                    for i in 0..<min(count, list.count) { me.handle(path: list[i], flags: eventFlags[i]) }
                }
                guard let s = FSEventStreamCreateRelativeToDevice(
                    nil, callback, &context, device, ["/"] as CFArray, since, 0, flags) else {
                    finish(.invalidateAll)
                    return
                }
                stream = s
                FSEventStreamSetDispatchQueue(s, queue)
                guard FSEventStreamStart(s) else { finish(.invalidateAll); return }
                queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.invalidateAll) }
            }
        }

        // Called on `queue`.
        func handle(path: String, flags: FSEventStreamEventFlags) {
            guard continuation != nil else { return }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyDone = true
                // Ask the daemon for anything it still holds, then answer.
                if let stream { FSEventStreamFlushAsync(stream) }
                queue.asyncAfter(deadline: .now() + 0.05) { [self] in finishIfDone() }
                return
            }
            if flags & Self.untrusted != 0 { poisoned = true }
            // Relative-to-device streams report "private/var/…" without the leading slash.
            paths.append(path.hasPrefix("/") ? path : "/" + path)
            if paths.count > maxEvents { poisoned = true }
        }

        func finishIfDone() {
            guard continuation != nil else { return }
            finish(poisoned ? .invalidateAll : .changed(paths))
        }

        func finish(_ result: JournalResult) {
            guard let cont = continuation else { return }
            continuation = nil
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                stream = nil
            }
            cont.resume(returning: result)
        }
    }

    public func openWatch(device: dev_t, since eventID: UInt64) -> (any JournalWatching)? {
        LiveWatch(device: device, since: eventID, maxEvents: maxEvents)
    }

    private final class LiveWatch: JournalWatching, @unchecked Sendable {
        let queue = DispatchQueue(label: "adk.fsevents-watch", qos: .utility)
        let maxEvents: Int
        var stream: FSEventStreamRef?
        // Shared between the callback queue and `drain`: lock-protected, so a backlog of replayed events on the
        // queue can never block the caller.
        let lock = NSLock()
        var paths: [String] = []
        var poisoned = false
        var total = 0
        var historyDone = false
        var closed = false

        init?(device: dev_t, since: UInt64, maxEvents: Int) {
            self.maxEvents = maxEvents
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let me = Unmanaged<LiveWatch>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
                for i in 0..<min(count, list.count) { me.handle(path: list[i], flags: eventFlags[i]) }
            }
            guard let s = FSEventStreamCreateRelativeToDevice(
                nil, callback, &context, device, ["/"] as CFArray, since, 0, flags) else { return nil }
            stream = s
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else {
                FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil
                return nil
            }
        }

        func handle(path: String, flags: FSEventStreamEventFlags) {   // on `queue`
            lock.lock(); defer { lock.unlock() }
            if closed { return }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { historyDone = true; return }
            if flags & Collector.untrusted != 0 { poisoned = true }
            total += 1
            if total > maxEvents { poisoned = true; paths = []; return }
            paths.append(path.hasPrefix("/") ? path : "/" + path)
        }

        private func state() -> (done: Bool, poisoned: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (historyDone, poisoned)
        }

        func drain() -> [String]? {
            lock.lock(); let s = closed ? nil : stream; lock.unlock()
            guard let s else { return nil }
            // The replay of old events must be complete before anything is trusted; bounded, then give up.
            let deadline = Date().addingTimeInterval(5)
            while true {
                FSEventStreamFlushSync(s)
                let st = state()
                if st.poisoned { return nil }
                if st.done { break }
                if Date() > deadline { return nil }
                Thread.sleep(forTimeInterval: 0.01)
            }
            lock.lock(); defer { lock.unlock() }
            if poisoned { return nil }
            defer { paths = [] }
            return paths
        }

        func close() {
            lock.lock()
            guard !closed, let s = stream else { lock.unlock(); return }
            closed = true
            stream = nil
            lock.unlock()
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
