import Darwin
import Foundation

/// Offers simulators whose runtime is no longer installed. Read-only: it asks `simctl` which devices are
/// unavailable, then measures each device's own folder. Cleanup is the per-UDID `simctl delete` (a tool command).
public struct UnavailableSimulatorScanner: Scanner {
    public let id = "dev-tools.simulators"

    private let devicesRoot: String
    private let candidates: [String]
    private let developer: SimctlEnvironment
    private let runner: any ToolProcessRunning
    private let timeout: Duration

    public init(devicesRoot: String, candidates: [String] = SimctlToolCommands.defaultCandidates,
                developer: SimctlEnvironment = .live, runner: any ToolProcessRunning = ToolCommandRunner(),
                timeout: Duration = .seconds(15)) {
        self.devicesRoot = devicesRoot
        self.candidates = candidates
        self.developer = developer
        self.runner = runner
        self.timeout = timeout
    }

    public static func live(environment: PathEnvironment) -> UnavailableSimulatorScanner {
        UnavailableSimulatorScanner(devicesRoot: SimctlToolCommands.devicesRoot(environment))
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        var st = stat()
        // Nothing to offer, and no process, without a Devices folder and developer tools.
        guard lstat(devicesRoot, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, developer.developerDir() != nil else { return }
        let toolContext = ToolCommandContext(environment: context.environment, runner: runner)
        let devices: [SimctlDevice]
        switch try await SimctlToolCommands.probe(context: toolContext, candidates: candidates, developer: developer,
                                                  timeout: timeout) {
        case .success(let d): devices = d
        case .failure(.noDeveloperDir), .failure(.noExecutable): return
        case .failure(let failure):
            await sink.warning(ScanWarning(kind: .scannerFailed, message: "Couldn't list unavailable simulators (\(failure)).",
                                           code: .scannerFailed(scannerID: id)))
            return
        }
        for device in devices where !device.isAvailable {
            try Task.checkCancellation()
            guard let item = await makeItem(device, context: context) else { continue }
            await sink.item(item)
        }
    }

    private func makeItem(_ device: SimctlDevice, context: ScanContext) async -> ScanItem? {
        guard ArgPattern.uppercaseUUID.matches(device.udid), !device.isBooted else { return nil }
        let folder = devicesRoot + "/" + device.udid
        var st = stat()
        guard lstat(folder, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == context.userID else { return nil }
        guard let data = device.dataPath else { return nil }
        let folderKey = PathCanonicalizer.key(folder)
        let dataKey = PathCanonicalizer.key(data)
        guard dataKey.components.starts(with: folderKey.components) else { return nil }
        guard context.pathGuard.check(folder).isAllowed else { return nil }
        guard let size = try? await context.size(URL(fileURLWithPath: folder)) else { return nil }
        return ScanItem(
            url: URL(fileURLWithPath: folder), displayName: "\(device.name) (\(device.runtimeShortName))",
            tool: "dev-caches", category: .systemJunk,
            sizeAllocated: size.allocatedBytes, sizeLogical: size.logicalBytes, fileCount: size.fileCount,
            lastModified: size.newestModification, tier: .review,
            explanation: "A simulator for \(device.runtimeShortName), which is no longer installed, so it can't start. "
                + "Deleting it with simctl removes the device and the apps and data inside it.",
            ruleID: SimctlToolCommands.ruleID,
            cleanupMethod: .toolCommand(command: "xcrun", arguments: ["simctl", "delete", device.udid]),
            requiresAppQuit: "com.apple.iphonesimulator")
    }
}
