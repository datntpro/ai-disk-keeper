import Darwin
import Foundation
import os

/// One process of the current user, read through libproc. Name, path and cwd only: argv is never read (it can hold secrets).
public struct ProcessRecord: Sendable, Hashable {
    public let pid: pid_t, ppid: pid_t, uid: uid_t
    /// `pbi_name`, falls back to `pbi_comm`.
    public let name: String
    /// `proc_pidpath`; nil when unreadable.
    public let executablePath: String?
    /// `PROC_PIDVNODEPATHINFO` `pvi_cdir`; nil when unreadable.
    public let cwd: String?
    /// `pbi_start_tvsec << 20 | pbi_start_tvusec`: identity guard against pid reuse.
    public let startID: UInt64
    /// `pbi_status` (`SSTOP` = stopped).
    public let status: UInt32
    /// `ri_diskio_*`, cumulative since the process started.
    public let diskBytesRead: UInt64, diskBytesWritten: UInt64
    public let cpuTimeNs: UInt64, physFootprint: UInt64

    public init(pid: pid_t, ppid: pid_t, uid: uid_t = 0, name: String, executablePath: String? = nil, cwd: String? = nil,
                startID: UInt64 = 0, status: UInt32 = 2, diskBytesRead: UInt64 = 0, diskBytesWritten: UInt64 = 0,
                cpuTimeNs: UInt64 = 0, physFootprint: UInt64 = 0) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name
        self.executablePath = executablePath; self.cwd = cwd; self.startID = startID; self.status = status
        self.diskBytesRead = diskBytesRead; self.diskBytesWritten = diskBytesWritten
        self.cpuTimeNs = cpuTimeNs; self.physFootprint = physFootprint
    }
}

public struct ProcessTableSnapshot: Sendable {
    public let at: ContinuousClock.Instant
    public let wall: Date
    public let records: [ProcessRecord]

    public init(at: ContinuousClock.Instant, wall: Date, records: [ProcessRecord]) {
        self.at = at; self.wall = wall; self.records = records
    }
}

public protocol ProcessTableReading: Sendable {
    /// nil = the table is unreadable.
    func snapshot() -> ProcessTableSnapshot?
}

public extension ProcessTableSnapshot {
    func children(of pid: pid_t) -> [ProcessRecord] { records.filter { $0.ppid == pid && $0.pid != pid } }

    /// Breadth-first over ppid; cycle-safe; never includes `pid` itself.
    func descendants(of pid: pid_t) -> [ProcessRecord] {
        var byParent: [pid_t: [ProcessRecord]] = [:]
        for r in records where r.pid != r.ppid { byParent[r.ppid, default: []].append(r) }
        var seen: Set<pid_t> = [pid]
        var out: [ProcessRecord] = []
        var queue: [pid_t] = [pid]
        var head = 0
        while head < queue.count {
            for child in byParent[queue[head], default: []] where seen.insert(child.pid).inserted {
                out.append(child)
                queue.append(child.pid)
            }
            head += 1
        }
        return out
    }

    /// Parent first, then its parent, and so on; cycle-safe; never includes `pid` itself.
    func ancestors(of pid: pid_t) -> [ProcessRecord] {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ProcessRecord] = []
        var seen: Set<pid_t> = [pid]
        var cursor = byPID[pid]?.ppid
        while let p = cursor, p > 0, seen.insert(p).inserted, let r = byPID[p] {
            out.append(r)
            cursor = r.ppid
        }
        return out
    }
}

/// libproc, own uid only (other users fail with EPERM and are skipped). No subprocess, no root, no `task_for_pid`.
public struct LibprocProcessTable: ProcessTableReading {
    public let userID: uid_t

    public init(userID: uid_t = getuid()) { self.userID = userID }

    private static let log = Logger(subsystem: "app.aidiskkeeper", category: "hostload")

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(max(t.denom, 1)))
    }()

    public func snapshot() -> ProcessTableSnapshot? {
        let started = ContinuousClock.now
        let wall = Date()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }
        var records: [ProcessRecord] = []
        records.reserveCapacity(Int(n) / 2)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            if let r = Self.read(pid, uid: userID) { records.append(r) }
        }
        let elapsed = ContinuousClock.now - started
        if elapsed > .milliseconds(50) {
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            Self.log.info("process table took \(ms, privacy: .public) ms")
        }
        return ProcessTableSnapshot(at: started, wall: wall, records: records)
    }

    static func read(_ pid: pid_t, uid: uid_t) -> ProcessRecord? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == uid else { return nil }
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } == 0
        }
        guard ok else { return nil }   // vanished or EPERM
        var name = cString(bsd.pbi_name)
        if name.isEmpty { name = cString(bsd.pbi_comm) }
        if name.isEmpty { name = "pid \(pid)" }
        var vnode = proc_vnodepathinfo()
        let vsize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let cwd: String? = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vsize) == vsize
            ? Optional(cString(vnode.pvi_cdir.vip_path)).flatMap { $0.isEmpty ? nil : $0 } : nil
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let path: String? = pathLen > 0 ? String(cString: pathBuf) : nil
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ProcessRecord(
            pid: pid, ppid: pid_t(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, name: name, executablePath: path, cwd: cwd,
            startID: (bsd.pbi_start_tvsec << 20) | (bsd.pbi_start_tvusec & 0xFFFFF),
            status: bsd.pbi_status, diskBytesRead: info.ri_diskio_bytesread, diskBytesWritten: info.ri_diskio_byteswritten,
            cpuTimeNs: ticks &* timebase.numer / timebase.denom, physFootprint: info.ri_phys_footprint)
    }

    /// A fixed-size C char array (imported as a tuple) up to its first NUL.
    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
