import Foundation
@testable import DiskKeeperCore

enum HostStatusFixtures {
    static let date = Date(timeIntervalSince1970: 1_795_000_000)   // 2026-11-18T11:06:40Z

    static func status(level: HostStatusLevel = .warn, running: Bool = true, at: Date = date, schemaVersion: Int = 1) -> HostStatus {
        var s = HostStatus(
            generatedAt: at, intervalSeconds: 30, running: running, generator: .init(version: "1.2", pid: 123), level: level,
            reasons: level == .ok ? [] : [.init(code: .lowFreeSpace, message: "Free space 13% (< 15%)")],
            disk: .init(volume: "/System/Volumes/Data", totalBytes: 500_000_000_000, freeBytes: 65_000_000_000, freePercent: 13,
                        thresholdPercent: 15, trendBytesPerHour: -1.2e9, timeToFullHours: nil),
            io: .init(readBytesPerSec: 1000, writeBytesPerSec: 2_000_000, busyPercent: 12, sampleSeconds: 30),
            load: .init(loadAverage1: 6.25, cpuCount: 10, memoryPressure: "normal"),
            topWriters: [.init(pid: 1, name: "claude", agent: "claude", worktree: "/Users/u/wt/a", writeBytesPerSec: 2_000_000),
                         .init(pid: 2, name: "mdworker", agent: nil, worktree: nil, writeBytesPerSec: 10)],
            worktrees: [.init(path: "/Users/u/wt/a", repo: "/Users/u/repo", writeBytesPerSec: 2_000_000, processCount: 3, agents: ["claude"])])
        s.schemaVersion = schemaVersion
        return s
    }

    static func data(_ s: HostStatus) throws -> Data { try HostStatus.makeEncoder().encode(s) }
}
