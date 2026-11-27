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
}
