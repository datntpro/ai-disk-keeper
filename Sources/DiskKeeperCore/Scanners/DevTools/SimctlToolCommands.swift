import Darwin
import Foundation

/// The allowlisted `xcrun simctl` commands (PLAN §7 invariant 19). Exactly two: a read-only list and a per-UDID
/// delete. Nothing else runs `xcrun`, and nothing here runs `brew`.
public enum SimctlToolCommands {
    public static let ruleID = "tool.devtools.simulator.unavailable"
    public static let listSpecID = "simctl.list.unavailable"
    public static let deleteSpecID = "simctl.delete"
    public static let listArguments = ["simctl", "list", "devices", "unavailable", "--json"]
    static let probeCacheKey = "simctl.list.unavailable"
    public static let defaultCandidates = ["/usr/bin/xcrun"]

    public static func devicesRoot(_ environment: PathEnvironment) -> String {
        environment.home + "/Library/Developer/CoreSimulator/Devices"
    }

    /// The compiled-in specs (the registry adds exactly this).
    public static var specs: [ToolCommandSpec] { makeSpecs() }

    /// `xcrunCandidates` and `developer` are injectable so tests point at a temp-dir script.
    static func makeSpecs(xcrunCandidates: [String] = defaultCandidates,
                          developer: SimctlEnvironment = .live) -> [ToolCommandSpec] {
        let executable: @Sendable (ToolCommandContext, ScanItem) -> ExecutableChoice = { _, _ in
            // No developer directory = no candidates, so `xcrun` is never started (no installer dialog).
            ExecutableChoice(candidates: developer.developerDir() == nil ? [] : xcrunCandidates)
        }
        let environment: @Sendable (ToolCommandContext, ScanItem) -> [String: String]? = { ctx, _ in
            guard let dir = developer.developerDir() else { return nil }
            return ctx.baseEnvironment.merging(["DEVELOPER_DIR": dir]) { $1 }
        }
        let root: @Sendable (PathEnvironment) -> String = { devicesRoot($0) }
        let list = ToolCommandSpec(
            id: listSpecID, command: "xcrun", ruleIDs: [ruleID], target: .path(root: root),
            template: listArguments.map { .literal($0) },
            bind: { _ in listArguments }, timeout: .seconds(15),
            executable: executable, environment: environment, isDestructive: false)
        let delete = ToolCommandSpec(
            id: deleteSpecID, command: "xcrun", ruleIDs: [ruleID], target: .path(root: root),
            template: [.literal("simctl"), .literal("delete"), .param(.uppercaseUUID)],
            bind: { item in
                let udid = item.url.lastPathComponent
                return ArgPattern.uppercaseUUID.matches(udid) ? ["simctl", "delete", udid] : nil
            },
            timeout: .seconds(60), executable: executable, environment: environment,
            revalidate: { ctx, item in
                let result: Result<[SimctlDevice], SimctlProbeFailure>
                do {
                    result = try await probe(context: ctx, candidates: xcrunCandidates, developer: developer)
                } catch {
                    return [.toolUnavailable(tool: "xcrun")]
                }
                guard case .success(let devices) = result else { return [.toolUnavailable(tool: "xcrun")] }
                guard let device = devices.first(where: { $0.udid == item.url.lastPathComponent && !$0.isAvailable }) else {
                    return [.inUseByTool(detail: "simulator is available again")]
                }
                if device.isBooted { return [.inUseByTool(detail: "simulator is running")] }
                return []
            },
            verifyAfter: { _, item, _ in
                var st = stat()
                if lstat(item.path, &st) != 0 && errno == ENOENT { return nil }
                return "simctl reported success but the simulator folder is still there"
            })
        return [list, delete]
    }

    // MARK: Read probe (scanner and re-validation)

    /// `simctl list devices unavailable --json`, parsed. Never launched without a developer directory.
    /// Plan time shares one probe per plan through the context's cache; execute time is always fresh.
    static func probe(context: ToolCommandContext, candidates: [String], developer: SimctlEnvironment,
                      resolver: ToolExecutableResolver = ToolExecutableResolver(),
                      timeout: Duration = .seconds(15)) async throws -> Result<[SimctlDevice], SimctlProbeFailure> {
        if let cached: [SimctlDevice] = context.probes?.value(probeCacheKey) { return .success(cached) }
        guard let dir = developer.developerDir() else { return .failure(.noDeveloperDir) }
        guard case .success(let exe) = resolver.resolve(candidates: candidates) else { return .failure(.noExecutable) }
        let env = context.baseEnvironment.merging(["DEVELOPER_DIR": dir]) { $1 }
        let result = try await context.runner.run(executable: exe, arguments: listArguments, environment: env,
                                                  timeout: timeout, maxStdout: ToolCommandRunner.probeStdoutCap)
        if result.timedOut { return .failure(.timedOut) }
        guard result.exitStatus == 0 else { return .failure(.exited(result.exitStatus)) }
        guard let devices = try? SimctlDeviceList.parse(result.stdout) else { return .failure(.badOutput) }
        context.probes?.store(probeCacheKey, devices)
        return .success(devices)
    }
}

enum SimctlProbeFailure: Error, Sendable, Hashable {
    case noDeveloperDir, noExecutable, timedOut, exited(Int32), badOutput
}
