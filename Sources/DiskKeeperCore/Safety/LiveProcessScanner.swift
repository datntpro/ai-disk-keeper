import Darwin
import Foundation

/// "Is any process executing from inside this bundle?" across ALL processes (daemons, XPC helpers, CLI
/// tools, login items), not just LaunchServices apps. Read-only (`proc_listallpids` + `proc_pidpath`).
public enum LiveProcessScanner {
    /// `true` if any process image lives under `bundlePath` (compared resolved and case-folded).
    /// `nil` = the process list could not be read (fail closed). Processes that vanish mid-scan are
    /// ignored; processes whose path can't be read (other users' daemons) can't live in a user-owned bundle.
    public static func isAnyProcessRunning(insideBundleAt bundlePath: String) -> Bool? {
        var prefixes: Set<String> = [fold(bundlePath)]
        if let r = realpath(bundlePath, nil) { prefixes.insert(fold(String(cString: r))); free(r) }

        let capacityHint = proc_listallpids(nil, 0)
        guard capacityHint > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacityHint) * 2 + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard len > 0 else { continue }
            let path = fold(String(cString: buffer))
            for p in prefixes where path.hasPrefix(p + "/") { return true }
        }
        return false
    }

    private static func fold(_ s: String) -> String {
        PathCanonicalizer.fold(PathNormalization.lexical(s))
    }
}
