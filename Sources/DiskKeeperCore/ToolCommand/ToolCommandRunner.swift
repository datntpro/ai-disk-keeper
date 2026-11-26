import Foundation

public struct ToolCommandResult: Sendable, Hashable {
    public let exitStatus: Int32
    public let stdout: Data
    /// Last 64 KiB of stderr, UTF-8 safe.
    public let stderrTail: String
    public let duration: Duration
    public let timedOut: Bool

    public init(exitStatus: Int32, stdout: Data = Data(), stderrTail: String = "", duration: Duration = .zero,
                timedOut: Bool = false) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderrTail = stderrTail
        self.duration = duration
        self.timedOut = timedOut
    }
}

/// The seam tests replace: nothing but this protocol ever starts a process for a tool command.
public protocol ToolProcessRunning: Sendable {
    /// Throws `CancellationError` when the task is cancelled (the process group is terminated first).
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
             maxStdout: Int) async throws -> ToolCommandResult
}

/// `ProcessRunner` wrapper: working directory `/`, the environment is exactly what the spec returned, no shell.
public struct ToolCommandRunner: ToolProcessRunning {
    public static let stderrTailBytes = 64 << 10
    public static let probeStdoutCap = 16 << 20
    public static let destructiveStdoutCap = 64 << 10
    private let killGrace: Duration

    public init(killGrace: Duration = .seconds(1)) { self.killGrace = killGrace }

    /// `PATH` is only the system directories; nothing from the app's own environment is inherited.
    public static func baseEnvironment(home: String) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": home]
    }

    public func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
                    maxStdout: Int) async throws -> ToolCommandResult {
        let runner = ProcessRunner(maxOutputBytes: max(maxStdout, Self.stderrTailBytes), killGrace: killGrace)
        let started = ContinuousClock.now
        do {
            let r = try await runner.run(executable: executable, arguments: arguments, environment: environment,
                                         currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
            return ToolCommandResult(exitStatus: r.exitStatus, stdout: r.stdout.prefix(maxStdout),
                                     stderrTail: Self.tail(r.stderr), duration: r.duration)
        } catch ProcessRunnerError.timedOut {
            return ToolCommandResult(exitStatus: -1, duration: ContinuousClock.now - started, timedOut: true)
        }
    }

    static func tail(_ data: Data) -> String {
        var slice = data.suffix(stderrTailBytes)
        // Drop a UTF-8 continuation prefix cut in half.
        while let b = slice.first, b & 0xC0 == 0x80 { slice = slice.dropFirst() }
        return String(decoding: slice, as: UTF8.self)
    }
}
