import Foundation

/// What `execute` learned about one tool command, for the report and the audit line.
public struct ToolRunRecord: Sendable, Hashable {
    /// Absolute executable + argv; nil when no command could be built.
    public let command: [String]?
    public let exitStatus: Int32?
    public let durationMs: Int?
    public let stderrTail: String?
    public let target: String?
    /// Set when an `intent` line was written for this run: the outcome line carries it back.
    public let intentID: UUID?

    public init(command: [String]?, exitStatus: Int32?, durationMs: Int?, stderrTail: String?, target: String?,
                intentID: UUID? = nil) {
        self.command = command; self.exitStatus = exitStatus; self.durationMs = durationMs
        self.stderrTail = stderrTail; self.target = target; self.intentID = intentID
    }
}

/// The engine's only entry point for tool commands: match → resolve → revalidate → run → verify.
public struct ToolCommandPerformer: Sendable {
    public let registry: ToolCommandRegistry
    public let context: ToolCommandContext
    public let resolver: ToolExecutableResolver
    /// When set, an `intent` line is written (and fsynced) before each command runs; the engine's outcome line follows.
    public let intentLog: AuditLog?

    public init(registry: ToolCommandRegistry, context: ToolCommandContext,
                resolver: ToolExecutableResolver = ToolExecutableResolver(), intentLog: AuditLog? = nil) {
        self.intentLog = intentLog
        self.registry = registry
        self.context = context
        self.resolver = resolver
    }

    public static func live(environment: PathEnvironment) -> ToolCommandPerformer {
        ToolCommandPerformer(registry: .builtIn,
                             context: ToolCommandContext(environment: environment, runner: ToolCommandRunner()),
                             intentLog: AuditLog(fileURL: AuditLog.defaultURL(environment: environment)))
    }

    // MARK: Plan

    /// Pure check (no probes): is this item an allowlisted command at all?
    public func allowlistBlockers(_ item: ScanItem) -> [CleanupBlocker] {
        if case .failure(let refusal) = registry.match(item, environment: context.environment) {
            return [.toolCommandNotAllowed(reason: refusal.reason)]
        }
        return []
    }

    /// Dry-run check: match, resolve the executable, build the environment, run the spec's re-validation.
    public func planCheck(_ item: ScanItem, probes: ToolProbeCache) async -> (blockers: [CleanupBlocker], snapshot: ToolCommandSnapshot?) {
        let prepared = await prepare(item, context: ToolCommandContext(environment: context.environment,
                                                                       runner: context.runner, probes: probes))
        switch prepared {
        case .blocked(let b): return (b, nil)
        case .ready(let p): return ([], p.snapshot)
        }
    }

    // MARK: Execute

    public enum Execution: Sendable {
        case blocked([CleanupBlocker], ToolRunRecord)
        case ran(CleanupOutcome, ToolRunRecord)
    }

    /// Re-resolves and re-validates (fresh, no cache), compares with the planned snapshot, then runs once.
    /// Anything that differs means the command is not run.
    public func execute(_ item: ScanItem, expected: ToolCommandSnapshot?) async -> Execution {
        switch await prepare(item, context: context) {
        case .blocked(let b): return .blocked(b, record(expected, result: nil))
        case .ready(let p):
            guard let expected else { return .blocked([.identityChanged], record(p.snapshot, result: nil)) }
            guard expected.executablePath == p.snapshot.executablePath else {
                return .blocked([.toolUnavailable(tool: p.spec.command)], record(expected, result: nil))
            }
            guard expected == p.snapshot else { return .blocked([.identityChanged], record(expected, result: nil)) }
            let tool = p.spec.command
            var intentID: UUID?
            if let intentLog {
                let id = UUID()
                let intent = AuditRecord(timestamp: Date(), runID: UUID(), itemID: item.id, path: item.path, bytes: item.sizeAllocated,
                                         action: .deletePermanently, result: AuditRecord.intentResult, trashPath: nil, ruleID: item.ruleID,
                                         tool: item.tool, reasons: [], error: nil, command: p.snapshot.command,
                                         toolTarget: p.snapshot.targetLabel, intentID: id)
                // Nothing runs unless the intent is durable: report "not run", not a failed run.
                do { try await intentLog.appendStandalone(intent) } catch {
                    return .blocked([.auditIntentNotWritten], record(p.snapshot, result: nil))
                }
                intentID = id
                // The intent write took milliseconds: look at the executable once more, right before the spawn.
                if ExecutableIdentity.of(path: p.executable.path) != p.snapshot.executableIdentity {
                    return .blocked([.identityChanged], record(p.snapshot, result: nil, intentID: id))
                }
            }
            let result: ToolCommandResult
            do {
                result = try await context.runner.run(executable: p.executable, arguments: p.argv, environment: p.environment,
                                                      timeout: p.spec.timeout, maxStdout: ToolCommandRunner.destructiveStdoutCap)
            } catch is CancellationError {
                return .ran(.failed("stopped"), record(p.snapshot, result: nil, intentID: intentID))
            } catch {
                return .ran(.failed("\(tool) could not start: \(error)"), record(p.snapshot, result: nil, intentID: intentID))
            }
            let rec = record(p.snapshot, result: result, intentID: intentID)
            if result.timedOut {
                let seconds = Int(p.spec.timeout.components.seconds)
                return .ran(.failed("\(tool) didn't finish within \(seconds) s. It may still complete in the background; scan again to check."), rec)
            }
            if result.exitStatus != 0 {
                let line = result.stderrTail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return .ran(.failed("\(tool) exited \(result.exitStatus): \(String(line.prefix(200)))"), rec)
            }
            if let verify = p.spec.verifyAfter, let failure = await verify(context, item, result) {
                return .ran(.failed(failure), rec)
            }
            return .ran(.ranCommand(exitStatus: 0), rec)
        }
    }

    // MARK: Internals

    private struct Prepared {
        let spec: ToolCommandSpec
        let executable: URL
        let argv: [String]
        let environment: [String: String]
        let snapshot: ToolCommandSnapshot
    }

    private enum Preparation { case blocked([CleanupBlocker]), ready(Prepared) }

    private func prepare(_ item: ScanItem, context: ToolCommandContext) async -> Preparation {
        let match: ToolCommandRegistry.Match
        switch registry.match(item, environment: context.environment) {
        case .failure(let refusal): return .blocked([.toolCommandNotAllowed(reason: refusal.reason)])
        case .success(let m): match = m
        }
        let spec = match.spec
        let exe: URL
        switch resolver.resolve(candidates: spec.executable(context, item).candidates, toolName: spec.command) {
        case .failure: return .blocked([.toolUnavailable(tool: spec.command)])
        case .success(let url): exe = url
        }
        let virtual = VirtualItemPath.parse(item.path)
        guard let env = spec.environment(context, item) else {
            return .blocked([.toolNotRunning(tool: spec.command, target: virtual?.target ?? "")])
        }
        let extra = await spec.revalidate(context, item)
        guard extra.isEmpty else { return .blocked(extra) }
        guard let identity = ExecutableIdentity.of(path: exe.path) else { return .blocked([.toolUnavailable(tool: spec.command)]) }
        let snapshot = ToolCommandSnapshot(specID: spec.id, executablePath: exe.path, argv: match.argv,
                                           environmentDisplay: env, targetLabel: virtual?.target, executableIdentity: identity)
        return .ready(Prepared(spec: spec, executable: exe, argv: match.argv, environment: env, snapshot: snapshot))
    }

    private static func utf8Tail(_ s: String, _ n: Int) -> Data {
        var d = Data(s.utf8).suffix(n)
        while let b = d.first, b & 0xC0 == 0x80 { d = d.dropFirst() }
        return d
    }

    private func record(_ snapshot: ToolCommandSnapshot?, result: ToolCommandResult?, intentID: UUID? = nil) -> ToolRunRecord {
        let stderr = result.map { String(decoding: Self.utf8Tail($0.stderrTail, 2048), as: UTF8.self) }
        return ToolRunRecord(command: snapshot?.command, exitStatus: result.map { $0.timedOut ? nil : $0.exitStatus } ?? nil,
                             durationMs: result.map { Int($0.duration.components.seconds * 1000 + $0.duration.components.attoseconds / 1_000_000_000_000_000) },
                             stderrTail: (stderr?.isEmpty ?? true) ? nil : stderr, target: snapshot?.targetLabel,
                             intentID: intentID)
    }
}
