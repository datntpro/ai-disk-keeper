import Darwin
import Foundation
import os

/// Result of a finished child process. Non-zero exit is NOT an error; inspect `exitStatus`.
public struct ProcessResult: Sendable, Hashable {
    /// `WEXITSTATUS`; for a child killed by a signal, `128 + signal`.
    public let exitStatus: Int32
    public let terminatedBySignal: Bool
    public let stdout: Data
    public let stderr: Data
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let duration: Duration

    public init(
        exitStatus: Int32, terminatedBySignal: Bool, stdout: Data, stderr: Data,
        stdoutTruncated: Bool, stderrTruncated: Bool, duration: Duration
    ) {
        self.exitStatus = exitStatus
        self.terminatedBySignal = terminatedBySignal
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.duration = duration
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed(executable: String, message: String)
    case timedOut(executable: String, after: Duration)
}

/// Runs a child process with a timeout, cancellation and a capped output buffer.
///
/// The child is spawned in its own process group; on timeout or cancellation the whole group gets
/// SIGTERM, then SIGKILL after `killGrace`, so grandchildren cannot keep the pipes open.
public struct ProcessRunner: Sendable {
    public let maxOutputBytes: Int
    public let killGrace: Duration

    public init(maxOutputBytes: Int = 16 << 20, killGrace: Duration = .seconds(1)) {
        self.maxOutputBytes = maxOutputBytes
        self.killGrace = killGrace
    }

    /// Never inherits the parent environment: `environment` is the complete env. stdin is `/dev/null`.
    /// Throws `CancellationError` if the task is cancelled (the process is terminated first),
    /// `ProcessRunnerError` otherwise. Never throws for a non-zero exit.
    public func run(
        executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL, timeout: Duration
    ) async throws -> ProcessResult {
        let rp = RunningProcess(
            executable: executable, maxOutputBytes: maxOutputBytes, killGrace: killGrace)
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: timeout)
                rp.terminate(reason: .timeout)
            } catch {}
        }
        defer { timeoutTask.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    rp.start(
                        arguments: arguments, environment: environment,
                        currentDirectory: currentDirectory, continuation: cont)
                }
            } onCancel: {
                rp.terminate(reason: .cancelled)
            }
        } catch RunningProcess.Timeout.timedOut {
            throw ProcessRunnerError.timedOut(executable: executable.path, after: timeout)
        }
    }
}

final class RunningProcess: @unchecked Sendable {
    enum Reason { case timeout, cancelled }
    enum Timeout: Error { case timedOut }

    private struct State {
        var out = Data()
        var err = Data()
        var outTruncated = false
        var errTruncated = false
        var pending = 3  // exit + two EOFs
        var pid: pid_t = 0
        var exitStatus: Int32 = 0
        var bySignal = false
        var reason: Reason?
        var finished = false
        var continuation: CheckedContinuation<ProcessResult, Error>?
        var startedAt = ContinuousClock.now
        var handles: [FileHandle] = []  // keep alive: the readability source dies with the handle
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let executable: URL
    private let maxOutputBytes: Int
    private let killGrace: Duration

    init(executable: URL, maxOutputBytes: Int, killGrace: Duration) {
        self.executable = executable
        self.maxOutputBytes = maxOutputBytes
        self.killGrace = killGrace
    }

    func start(
        arguments: [String], environment: [String: String], currentDirectory: URL,
        continuation: CheckedContinuation<ProcessResult, Error>
    ) {
        let cancelledEarly = lock.withLock { s -> Bool in
            s.continuation = continuation
            s.startedAt = .now
            if s.reason != nil {
                s.finished = true
                s.continuation = nil
                return true
            }
            return false
        }
        if cancelledEarly {
            continuation.resume(throwing: CancellationError())
            return
        }

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            fail(ProcessRunnerError.launchFailed(executable: executable.path, message: "pipe() failed"))
            return
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, currentDirectory.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // Reset signal dispositions/mask so an ignored SIGTERM in this process is not inherited.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setflags(
            &attr,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &fa, &attr, argv, envp)
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            fail(
                ProcessRunnerError.launchFailed(
                    executable: executable.path, message: String(cString: strerror(rc))))
            return
        }
        let spawned = pid
        let reasonAlready = lock.withLock { s -> Reason? in
            s.pid = spawned
            return s.reason
        }

        drain(fd: outPipe[0], isStdout: true)
        drain(fd: errPipe[0], isStdout: false)
        DispatchQueue.global(qos: .utility).async { [self] in
            var st: Int32 = 0
            while waitpid(spawned, &st, 0) < 0 && errno == EINTR {}
            exited(st)
        }
        if let reasonAlready { signalGroup(reason: reasonAlready) }
    }

    private func fail(_ error: Error) {
        let cont = lock.withLock { s -> CheckedContinuation<ProcessResult, Error>? in
            s.finished = true
            defer { s.continuation = nil }
            return s.continuation
        }
        cont?.resume(throwing: error)
    }

    private func drain(fd: Int32, isStdout: Bool) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        lock.withLock { $0.handles.append(handle) }
        handle.readabilityHandler = { [self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                try? h.close()
                lock.withLock { s in s.handles.removeAll { $0 === h } }
                latchDown()
                return
            }
            lock.withLock { s in
                if isStdout {
                    let room = maxOutputBytes - s.out.count
                    if data.count > room { s.outTruncated = true }
                    if room > 0 { s.out.append(data.prefix(room)) }
                } else {
                    let room = maxOutputBytes - s.err.count
                    if data.count > room { s.errTruncated = true }
                    if room > 0 { s.err.append(data.prefix(room)) }
                }
            }
        }
    }

    private func exited(_ status: Int32) {
        lock.withLock { s in
            let sig = status & 0x7f
            if sig == 0 {
                s.exitStatus = (status >> 8) & 0xff
            } else {
                s.bySignal = true
                s.exitStatus = 128 + sig
            }
        }
        latchDown()
    }

    private func latchDown() {
        let done = lock.withLock { s -> (CheckedContinuation<ProcessResult, Error>, Result<ProcessResult, Error>)? in
            s.pending -= 1
            guard s.pending == 0, !s.finished, let cont = s.continuation else { return nil }
            s.finished = true
            s.continuation = nil
            switch s.reason {
            case .cancelled?: return (cont, .failure(CancellationError()))
            case .timeout?: return (cont, .failure(Timeout.timedOut))
            case nil:
                let r = ProcessResult(
                    exitStatus: s.exitStatus, terminatedBySignal: s.bySignal,
                    stdout: s.out, stderr: s.err,
                    stdoutTruncated: s.outTruncated, stderrTruncated: s.errTruncated,
                    duration: ContinuousClock.now - s.startedAt)
                return (cont, .success(r))
            }
        }
        if let (cont, result) = done { cont.resume(with: result) }
    }

    func terminate(reason: Reason) {
        let proceed = lock.withLock { s -> Bool in
            guard !s.finished, s.reason == nil else { return false }
            s.reason = reason
            return s.pid > 0
        }
        if proceed { signalGroup(reason: reason) }
    }

    private func signalGroup(reason: Reason) {
        let pid = lock.withLock { $0.pid }
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        let grace = killGrace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace.timeInterval) { [self] in
            let finished = lock.withLock { $0.finished }
            if !finished { kill(-pid, SIGKILL) }
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
