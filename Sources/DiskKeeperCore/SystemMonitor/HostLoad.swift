import Foundation

/// One own-uid process with what it did to the disk during the last tick. Name, agent and worktree only (no argv).
public struct HostProcessIO: Sendable, Hashable, Identifiable {
    public var id: ProcessKey { ProcessKey(pid: pid, startID: startID) }
    public let pid: pid_t
    public let startID: UInt64
    public let name: String
    /// What the process is (`node`, `git`, `spotlight`, …).
    public let kind: AgentKind
    /// The agent CLI it runs under (itself or the nearest ancestor), nil when there is none.
    public let agent: AgentKind?
    public let worktree: WorktreeRef?
    public let readBytesPerSec: Double, writeBytesPerSec: Double
    /// Written since the process started.
    public let totalBytesWritten: UInt64
}

public struct WorktreeIO: Sendable, Hashable, Identifiable {
    public var id: String { worktree.root }
    public let worktree: WorktreeRef
    public let readBytesPerSec: Double, writeBytesPerSec: Double
    public let processCount: Int
    public let agents: [AgentKind]
}

public struct AgentIO: Sendable, Hashable, Identifiable {
    public var id: AgentKind { kind }
    public let kind: AgentKind
    public let readBytesPerSec: Double, writeBytesPerSec: Double
    public let processCount: Int
}

public struct HostLoadSnapshot: Sendable {
    public let at: Date
    public let disk: DiskActivity?
    public let processes: [HostProcessIO]
    public let byWorktree: [WorktreeIO]
    public let byAgent: [AgentIO]
    /// Disk writes minus attributed writes: short-lived processes, other users, the kernel. nil without a disk reading.
    public let unattributedWriteBytesPerSec: Double?
    public let loadAverage: (Double, Double, Double)
    public let cpuCount: Int
    public let freeSpace: FreeSpaceStatus?
}

/// One host-load tick: process table → rates → agent + worktree attribution, plus the whole-disk counters.
/// Own-uid processes only; no subprocess.
public actor HostLoadSampler {
    public static let processLimit = 50

    private let table: any ProcessTableReading
    private let disk: any DiskStatisticsReading
    private var attribution: WorktreeAttribution
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let freeSpace: @Sendable () -> FreeSpaceStatus?
    private var rates = IORateTracker()
    private var diskTracker = DiskActivityTracker()

    public init(table: any ProcessTableReading = LibprocProcessTable(), disk: any DiskStatisticsReading = LiveDiskStatisticsReader(),
                attribution: WorktreeAttribution, clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                freeSpace: @escaping @Sendable () -> FreeSpaceStatus? = { nil }) {
        self.table = table
        self.disk = disk
        self.attribution = attribution
        self.clock = clock
        self.freeSpace = freeSpace
    }

    public func tick() -> HostLoadSnapshot {
        let diskActivity = disk.read().flatMap { diskTracker.update($0, at: clock()) }
        var processes: [HostProcessIO] = []
        if let snap = table.snapshot() {
            attribution.resetCache()
            let ancestry = Dictionary(snap.records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            for rate in rates.rates(snap) {
                let r = rate.record
                let chain = Self.ancestors(of: r, in: ancestry)
                processes.append(HostProcessIO(
                    pid: r.pid, startID: r.startID, name: r.name, kind: AgentClassifier.classify(r),
                    agent: AgentClassifier.agent(of: r, ancestors: chain), worktree: r.cwd.flatMap { attribution.root(forCWD: $0) },
                    readBytesPerSec: rate.readBytesPerSec, writeBytesPerSec: rate.writeBytesPerSec, totalBytesWritten: r.diskBytesWritten))
            }
        }
        let attributed = processes.reduce(0) { $0 + $1.writeBytesPerSec }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return HostLoadSnapshot(
            at: Date(), disk: diskActivity,
            processes: Array(processes.filter { $0.readBytesPerSec > 0 || $0.writeBytesPerSec > 0 }
                .sorted { $0.writeBytesPerSec != $1.writeBytesPerSec ? $0.writeBytesPerSec > $1.writeBytesPerSec : $0.pid < $1.pid }
                .prefix(Self.processLimit)),
            byWorktree: Self.byWorktree(processes), byAgent: Self.byAgent(processes),
            unattributedWriteBytesPerSec: diskActivity.map { max(0, $0.writeBytesPerSec - attributed) },
            loadAverage: (load[0], load[1], load[2]), cpuCount: ProcessInfo.processInfo.activeProcessorCount, freeSpace: freeSpace())
    }

    private static func ancestors(of r: ProcessRecord, in byPID: [pid_t: ProcessRecord]) -> [ProcessRecord] {
        var out: [ProcessRecord] = []
        var seen: Set<pid_t> = [r.pid]
        var cursor = r.ppid
        while cursor > 0, seen.insert(cursor).inserted, let p = byPID[cursor] {
            out.append(p)
            cursor = p.ppid
        }
        return out
    }

    /// Sums over every attributed process (not only the top 50), so the rows add up to the attributed total.
    static func byWorktree(_ processes: [HostProcessIO]) -> [WorktreeIO] {
        var sums: [String: (ref: WorktreeRef, read: Double, write: Double, count: Int, agents: Set<AgentKind>)] = [:]
        for p in processes {
            guard let w = p.worktree else { continue }
            var s = sums[w.root] ?? (w, 0, 0, 0, [])
            s.read += p.readBytesPerSec; s.write += p.writeBytesPerSec; s.count += 1
            if let a = p.agent { s.agents.insert(a) }
            sums[w.root] = s
        }
        return sums.values
            .map { WorktreeIO(worktree: $0.ref, readBytesPerSec: $0.read, writeBytesPerSec: $0.write, processCount: $0.count,
                              agents: $0.agents.sorted { $0.rawValue < $1.rawValue }) }
            .sorted { $0.writeBytesPerSec != $1.writeBytesPerSec ? $0.writeBytesPerSec > $1.writeBytesPerSec : $0.worktree.root < $1.worktree.root }
    }

    /// A process counts for its agent CLI, else for what it is (`spotlight`, `docker`, `other`).
    static func byAgent(_ processes: [HostProcessIO]) -> [AgentIO] {
        var sums: [AgentKind: (read: Double, write: Double, count: Int)] = [:]
        for p in processes {
            let k = p.agent ?? p.kind
            var s = sums[k] ?? (0, 0, 0)
            s.read += p.readBytesPerSec; s.write += p.writeBytesPerSec; s.count += 1
            sums[k] = s
        }
        return sums.map { AgentIO(kind: $0.key, readBytesPerSec: $0.value.read, writeBytesPerSec: $0.value.write, processCount: $0.value.count) }
            .sorted { $0.writeBytesPerSec != $1.writeBytesPerSec ? $0.writeBytesPerSec > $1.writeBytesPerSec : $0.kind.rawValue < $1.kind.rawValue }
    }
}
