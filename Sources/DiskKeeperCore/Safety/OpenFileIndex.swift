import Darwin
import Foundation

/// What one process keeps on files: vnode descriptors and file-backed memory mappings (a mapping outlives its fd).
public struct ProcessFiles: Sendable, Hashable {
    public let open: [String]
    public let mapped: [String]
    public init(open: [String] = [], mapped: [String] = []) { self.open = open; self.mapped = mapped }
}

public enum FileReadResult: Error, Sendable, Hashable {
    case files(ProcessFiles)
    /// The process exited while we looked: it holds nothing now.
    case gone
    /// The kernel refused (`EPERM`/`EACCES`, anything but "gone"): the process may hold files we cannot see. Callers fail closed.
    case denied
}

public protocol OpenFileReading: Sendable {
    func read(pid: pid_t) -> FileReadResult
}

/// libproc only: `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`, and `PROC_PIDREGIONPATHINFO` for mappings.
/// No `lsof`, no subprocess, no root.
public struct LibprocOpenFiles: OpenFileReading {
    public init() {}

    public func read(pid: pid_t) -> FileReadResult {
        let fds: [String]
        switch openPaths(pid) {
        case .success(let p): fds = p
        case .failure(let f): return f
        }
        switch mappedPaths(pid) {
        case .success(let m): return .files(ProcessFiles(open: fds, mapped: m))
        case .failure(let f): return f
        }
    }

    private func classify(_ code: Int32) -> FileReadResult { code == ESRCH ? .gone : .denied }

    private func openPaths(_ pid: pid_t) -> Result<[String], FileReadResult> {
        errno = 0
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if need < 0 { return .failure(classify(errno)) }
        if need == 0 { return .success([]) }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Headroom: descriptors may be opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 32)
        errno = 0
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        if got < 0 { return .failure(classify(errno)) }
        var out: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }   // closed meanwhile
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasPrefix("/") { out.append(path) }
        }
        return .success(out)
    }

    /// Walks the address space; keeps file-backed regions, deduplicated by path.
    private func mappedPaths(_ pid: pid_t) -> Result<[String], FileReadResult> {
        var seen = Set<String>()
        var out: [String] = []
        var address: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var regions = 0
        while regions < 200_000 {
            var info = proc_regionwithpathinfo()
            errno = 0
            let got = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, size)
            if got != size {
                // End of the address space (0 / EINVAL) is normal; a refusal on the very first call is not.
                let code = errno
                if regions == 0 && (code == EPERM || code == EACCES) { return .failure(.denied) }
                if regions == 0 && code == ESRCH { return .failure(.gone) }
                break
            }
            regions += 1
            let path = withUnsafeBytes(of: info.prp_vip.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            if path.hasPrefix("/"), seen.insert(path).inserted { out.append(path) }
            let next = info.prp_prinfo.pri_address &+ info.prp_prinfo.pri_size
            if next <= address { break }
            address = next
        }
        return .success(out)
    }
}
