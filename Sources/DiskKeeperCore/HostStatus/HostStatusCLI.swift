import Foundation

/// `adk status`: pure, so it is tested without a process. Reads one file; never starts or wakes the app, no network.
/// Exit codes: 0 ok, 10 warn, 20 critical, 3 stale/missing/not running, 2 usage, 4 unreadable or schema mismatch.
public enum HostStatusCLI {
    public struct Output: Equatable, Sendable {
        public var stdout: String, stderr: String
        public var exitCode: Int32
    }

    public static let defaultMaxAge = 120.0
    public static let usage = """
        usage: adk status [--json] [--worktree PATH] [--max-age SEC] [--quiet]
          Prints the machine status AI Disk Keeper publishes (disk space, disk writes, load).
          exit: 0 ok, 10 warn, 20 critical, 3 stale/missing/app not running, 2 usage, 4 unreadable
          --json          print status.json as is
          --worktree PATH show the write rate and processes of the worktree holding PATH
          --max-age SEC   older than this counts as stale (default 120)
          --quiet         no output, only the exit code

        """

    public static func run(args: [String], statusURL: URL, now: Date) -> Output {
        var json = false, quiet = false, worktree: String?, maxAge = defaultMaxAge
        var rest = args[...]
        guard let command = rest.popFirst() else { return Output(stdout: "", stderr: usage, exitCode: 2) }
        if command == "-h" || command == "--help" || command == "help" { return Output(stdout: usage, stderr: "", exitCode: 0) }
        guard command == "status" else { return fail("unknown command '\(command)'") }
        while let arg = rest.popFirst() {
            switch arg {
            case "--json": json = true
            case "--quiet", "-q": quiet = true
            case "--worktree":
                guard let v = rest.popFirst(), !v.isEmpty else { return fail("--worktree needs a path") }
                worktree = v
            case "--max-age":
                guard let v = rest.popFirst(), let n = Double(v), n >= 0, n.isFinite else { return fail("--max-age needs a number of seconds") }
                maxAge = n
            case "-h", "--help": return Output(stdout: usage, stderr: "", exitCode: 0)
            default: return fail("unknown option '\(arg)'")
            }
        }

        func out(_ stdout: String, _ stderr: String, _ code: Int32) -> Output {
            quiet ? Output(stdout: "", stderr: "", exitCode: code) : Output(stdout: stdout, stderr: stderr, exitCode: code)
        }

        guard let data = try? Data(contentsOf: statusURL) else {
            return out("", "adk: no status file (is AI Disk Keeper running with \"Publish machine status\" on?)\n", 3)
        }
        struct Probe: Decodable { var schemaVersion: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return out("", "adk: status file is unreadable\n", 4) }
        guard probe.schemaVersion == HostStatus.schemaVersion else {
            return out("", "adk: status schema \(probe.schemaVersion) is not supported (this adk reads \(HostStatus.schemaVersion)); update adk\n", 4)
        }
        guard let status = try? HostStatus.makeDecoder().decode(HostStatus.self, from: data) else {
            return out("", "adk: status file is unreadable\n", 4)
        }
        guard status.running else { return out("", "adk: AI Disk Keeper is not running (status is from its last quit)\n", 3) }
        let age = max(0, now.timeIntervalSince(status.generatedAt))
        guard age <= maxAge else { return out("", "adk: status is stale (\(Int(age)) s old, max \(Int(maxAge)) s)\n", 3) }

        let code: Int32 = switch status.level { case .ok: 0; case .warn: 10; case .critical: 20 }
        if json { return out(String(decoding: data, as: UTF8.self) + (data.last == 0x0A ? "" : "\n"), "", code) }
        return out(text(status, worktree: worktree), "", code)
    }

    private static func fail(_ message: String) -> Output { Output(stdout: "", stderr: "adk: \(message)\n" + usage, exitCode: 2) }

    static func text(_ s: HostStatus, worktree: String?) -> String {
        var lines = ["level: \(s.level.rawValue)"]
        lines += s.reasons.map { "- \($0.message)" }
        if let d = s.disk {
            var line = "disk: \(String(format: "%.1f", d.freePercent))% free (\(bytes(Double(d.freeBytes))) of \(bytes(Double(d.totalBytes))))"
            if let t = d.trendBytesPerHour { line += ", \(t < 0 ? "-" : "+")\(bytes(abs(t)))/h" }
            if let h = d.timeToFullHours { line += ", full in about \(Int(h.rounded())) h" }
            lines.append(line)
        } else {
            lines.append("disk: unknown")
        }
        if let io = s.io { lines.append("io: writes \(bytes(io.writeBytesPerSec))/s, reads \(bytes(io.readBytesPerSec))/s") }
        if let path = worktree {
            let wanted = normalize(path)
            let match = s.worktrees.filter { wanted == $0.path || wanted.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
            if let w = match {
                lines.append("worktree \(w.path): writes \(bytes(w.writeBytesPerSec))/s, \(w.processCount) process(es)"
                    + (w.agents.isEmpty ? "" : ", agents: \(w.agents.joined(separator: ", "))"))
                for p in s.topWriters where p.worktree == w.path {
                    lines.append("  \(p.name) (pid \(p.pid)): \(bytes(p.writeBytesPerSec))/s")
                }
            } else {
                lines.append("worktree \(wanted): no recorded disk activity")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = FileManager.default.currentDirectoryPath + "/" + p }
        p = (p as NSString).standardizingPath
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: "%.1f %@", v, units[i])
    }
}
