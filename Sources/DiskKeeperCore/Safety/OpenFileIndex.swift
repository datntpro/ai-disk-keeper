import Darwin
import Foundation

/// The vnode paths one process holds open (regular files and directories; sockets, pipes and the like are skipped).
public struct OpenFileSet: Sendable, Hashable {
    public let pid: pid_t
    public let paths: [String]
    public init(pid: pid_t, paths: [String]) { self.pid = pid; self.paths = paths }
}

public protocol OpenFileReading: Sendable {
    /// Open vnode paths of `pid`. nil = the descriptor table could not be read at all (EPERM, vanished).
    func openPaths(of pid: pid_t) -> [String]?
}

/// libproc only: `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`. No `lsof`, no subprocess, no root.
public struct LibprocOpenFiles: OpenFileReading {
    public init() {}

    public func openPaths(of pid: pid_t) -> [String]? {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return need == 0 ? [] : nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Headroom: descriptors may be opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 32)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return got == 0 ? [] : nil }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if path.hasPrefix("/") { out.append(path) }
        }
        return out
    }
}
