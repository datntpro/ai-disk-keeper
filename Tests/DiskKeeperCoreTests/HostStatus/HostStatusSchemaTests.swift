import XCTest
@testable import DiskKeeperCore

final class HostStatusSchemaTests: XCTestCase {
    func testGolden() throws {
        let json = String(decoding: try HostStatusFixtures.data(HostStatusFixtures.status()), as: UTF8.self)
        XCTAssertEqual(json, Self.golden)
    }

    func testRoundTripAndUnknownKeys() throws {
        let original = HostStatusFixtures.status()
        var object = try JSONSerialization.jsonObject(with: HostStatusFixtures.data(original)) as! [String: Any]
        object["futureField"] = ["a": 1]
        var load = object["load"] as! [String: Any]; load["extra"] = true; object["load"] = load
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try HostStatus.makeDecoder().decode(HostStatus.self, from: data), original)
    }

    func testUnknownValuesAreNullNotOmitted() throws {
        var s = HostStatusFixtures.status(); s.disk = nil; s.io = nil; s.load.memoryPressure = nil
        let object = try JSONSerialization.jsonObject(with: HostStatusFixtures.data(s)) as! [String: Any]
        for key in ["disk", "io", "inventory"] { XCTAssertTrue(object[key] is NSNull, key) }
        XCTAssertTrue((object["load"] as! [String: Any])["memoryPressure"] is NSNull)
        let writers = object["topWriters"] as! [[String: Any]]
        XCTAssertTrue(writers[1]["agent"] is NSNull); XCTAssertTrue(writers[1]["worktree"] is NSNull)
    }

    func testLimitsAndNoArgv() throws {
        let many = (0..<40).map { HostStatus.Writer(pid: Int32($0), name: "p", agent: nil, worktree: nil, writeBytesPerSec: 1) }
        let wts = (0..<40).map { HostStatus.Worktree(path: "/w\($0)", repo: "/r", writeBytesPerSec: 1, processCount: 1, agents: []) }
        let s = HostStatus(generatedAt: Date(), intervalSeconds: 30, running: true, generator: .init(version: "1", pid: 1), level: .ok, reasons: [],
                           disk: nil, io: nil, load: .init(loadAverage1: 0, cpuCount: 1, memoryPressure: nil), topWriters: many, worktrees: wts)
        XCTAssertEqual(s.topWriters.count, 10); XCTAssertEqual(s.worktrees.count, 20)
        let object = try JSONSerialization.jsonObject(with: HostStatusFixtures.data(s)) as! [String: Any]
        let keys = Set(object.keys)
        XCTAssertFalse(keys.contains("argv") || keys.contains("cmdline"))
    }

    func testComposerBuildsStatusFromSnapshot() {
        let wt = WorktreeRef(root: "/w/a", repoRoot: "/w/main", isLinkedWorktree: true)
        let p = HostProcessIO(pid: 7, startID: 1, name: "claude", kind: .claude, agent: .claude, worktree: wt,
                              readBytesPerSec: 0, writeBytesPerSec: 500, totalBytesWritten: 9)
        let idle = HostProcessIO(pid: 8, startID: 1, name: "zzz", kind: .other, agent: nil, worktree: nil,
                                 readBytesPerSec: 5, writeBytesPerSec: 0, totalBytesWritten: 0)
        let free = FreeSpaceStatus(freeBytes: 65_000_000_000, totalBytes: 500_000_000_000, thresholdPercent: 15,
                                   trend: .init(bytesPerHour: -1e9, timeToFull: 65 * 3600, r2: 0.9))
        let snap = HostLoadSnapshot(
            at: Date(), disk: DiskActivity(readBytesPerSec: 1, writeBytesPerSec: 600, busyFraction: 0.123), processes: [p, idle],
            byWorktree: [WorktreeIO(worktree: wt, readBytesPerSec: 0, writeBytesPerSec: 500, processCount: 1, agents: [.claude])], byAgent: [],
            unattributedWriteBytesPerSec: 100, loadAverage: (2, 1, 1), cpuCount: 10, memoryPressure: .normal, freeSpace: free)
        var composer = HostStatusComposer(version: "9", pid: 42)
        let s = composer.compose(snap, thresholdPercent: 15, sampleSeconds: 30, now: HostStatusFixtures.date)
        XCTAssertEqual(s.level, .warn)
        XCTAssertEqual(s.reasons.map(\.code), [.lowFreeSpace])
        XCTAssertEqual(s.disk?.freePercent, 13)
        XCTAssertEqual(s.disk?.timeToFullHours ?? 0, 65, accuracy: 0.001)
        XCTAssertEqual(s.io?.busyPercent, 12.3)
        XCTAssertEqual(s.topWriters.map(\.pid), [7], "idle writers are not listed")
        XCTAssertEqual(s.topWriters.first?.worktree, "/w/a")
        XCTAssertEqual(s.worktrees.first?.repo, "/w/main")
        XCTAssertEqual(s.generator.pid, 42)
        XCTAssertEqual(s.load.memoryPressure, "normal")
        XCTAssertNil(s.inventory)
    }

    static let golden = """
    {
      "disk" : {
        "freeBytes" : 65000000000,
        "freePercent" : 13,
        "thresholdPercent" : 15,
        "timeToFullHours" : null,
        "totalBytes" : 500000000000,
        "trendBytesPerHour" : -1200000000,
        "volume" : "/System/Volumes/Data"
      },
      "generatedAt" : "2026-11-18T11:06:40Z",
      "generator" : {
        "app" : "AI Disk Keeper",
        "pid" : 123,
        "version" : "1.2"
      },
      "intervalSeconds" : 30,
      "inventory" : null,
      "io" : {
        "busyPercent" : 12,
        "readBytesPerSec" : 1000,
        "sampleSeconds" : 30,
        "writeBytesPerSec" : 2000000
      },
      "level" : "warn",
      "load" : {
        "cpuCount" : 10,
        "loadAverage1" : 6.25,
        "memoryPressure" : "normal"
      },
      "reasons" : [
        {
          "code" : "lowFreeSpace",
          "message" : "Free space 13% (< 15%)"
        }
      ],
      "running" : true,
      "schemaVersion" : 1,
      "topWriters" : [
        {
          "agent" : "claude",
          "name" : "claude",
          "pid" : 1,
          "worktree" : "/Users/u/wt/a",
          "writeBytesPerSec" : 2000000
        },
        {
          "agent" : null,
          "name" : "mdworker",
          "pid" : 2,
          "worktree" : null,
          "writeBytesPerSec" : 10
        }
      ],
      "worktrees" : [
        {
          "agents" : [
            "claude"
          ],
          "path" : "/Users/u/wt/a",
          "processCount" : 3,
          "repo" : "/Users/u/repo",
          "writeBytesPerSec" : 2000000
        }
      ]
    }
    """
}
