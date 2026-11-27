import Foundation

public struct ProcessKey: Sendable, Hashable {
    public let pid: pid_t, startID: UInt64
    public init(pid: pid_t, startID: UInt64) { self.pid = pid; self.startID = startID }
}

/// Bytes per second of one process between two ticks.
public struct ProcessIORate: Sendable, Hashable {
    public let record: ProcessRecord
    public let readBytesPerSec: Double
    public let writeBytesPerSec: Double
    public var key: ProcessKey { ProcessKey(pid: record.pid, startID: record.startID) }
}

public struct IORateTick: Sendable {
    public let rates: [ProcessIORate]
    /// Processes seen last tick and gone now. The kernel keeps no child disk-io counter, so what they wrote after
    /// the last tick is only visible as "other processes" in the whole-disk numbers.
    public let exited: [ProcessKey]
    /// Their cumulative bytes written at the last tick they were seen (informational).
    public let exitedBytesWritten: UInt64
}

/// Deltas of the cumulative `ri_diskio_*` counters per `(pid, startID)`. A new `startID` (pid reuse), a first
/// sighting or a counter that went down gives no rate for that tick: a rate is never negative.
public struct IORateTracker: Sendable {
    private var previous: [ProcessKey: (read: UInt64, written: UInt64)] = [:]
    private var previousAt: ContinuousClock.Instant?

    public init() {}

    public mutating func update(_ snap: ProcessTableSnapshot) -> IORateTick {
        let seconds: Double? = previousAt.map {
            let d = snap.at - $0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        var next: [ProcessKey: (read: UInt64, written: UInt64)] = [:]
        next.reserveCapacity(snap.records.count)
        var rates: [ProcessIORate] = []
        for r in snap.records {
            let key = ProcessKey(pid: r.pid, startID: r.startID)
            next[key] = (r.diskBytesRead, r.diskBytesWritten)
            guard let seconds, seconds > 0, let old = previous[key],
                  r.diskBytesRead >= old.read, r.diskBytesWritten >= old.written else { continue }
            rates.append(ProcessIORate(record: r, readBytesPerSec: Double(r.diskBytesRead - old.read) / seconds,
                                       writeBytesPerSec: Double(r.diskBytesWritten - old.written) / seconds))
        }
        let gone = previous.filter { next[$0.key] == nil }
        previous = next
        previousAt = snap.at
        return IORateTick(rates: rates, exited: Array(gone.keys),
                          exitedBytesWritten: gone.values.reduce(0) { $0 &+ $1.written })
    }

    public mutating func rates(_ snap: ProcessTableSnapshot) -> [ProcessIORate] { update(snap).rates }
}
