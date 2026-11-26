import Foundation

/// Which launch services are loaded or running, from `launchctl print gui/<uid>`.
///
/// This is the ONLY launchctl call the app makes, and `print` is its only subcommand: it reads, never loads,
/// unloads or changes anything. `system/` is not read (it needs root), so daemons show as unknown.
public struct LaunchctlLoadedState: Sendable {
    public enum Result: Sendable, Equatable {
        /// label → state for every service the user's GUI domain knows.
        case loaded([String: StartupItem.LoadState])
        case unavailable
    }

    /// The only subcommand. `load(userID:)` appends the domain target and nothing else.
    static let arguments = ["print"]

    private let executable: URL
    private let runner: ProcessRunner
    private let timeout: Duration

    public init(executable: URL = URL(fileURLWithPath: "/bin/launchctl"),
                runner: ProcessRunner = ProcessRunner(maxOutputBytes: 8 << 20), timeout: Duration = .seconds(5)) {
        self.executable = executable
        self.runner = runner
        self.timeout = timeout
    }

    /// Never throws except `CancellationError`: a timeout, a failure or a missing tool is `.unavailable`.
    public func load(userID: uid_t) async throws -> Result {
        do {
            let r = try await runner.run(
                executable: executable, arguments: Self.arguments + ["gui/\(userID)"],
                environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
            guard r.exitStatus == 0 else { return .unavailable }
            return .loaded(Self.parse(r.stdoutString))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable
        }
    }

    /// Reads the `services = { … }` block: lines of `<pid or -> <status> <label>`.
    static func parse(_ output: String) -> [String: StartupItem.LoadState] {
        var states: [String: StartupItem.LoadState] = [:]
        var inServices = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inServices {
                if line == "services = {" { inServices = true }
                continue
            }
            if line == "}" { break }
            let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3 else { continue }
            let label = parts[2].trimmingCharacters(in: .whitespaces)
            if parts[0] == "-" {
                states[label] = .loaded
            } else if let pid = Int32(parts[0]) {
                states[label] = .running(pid: pid)
            }
        }
        return states
    }
}
