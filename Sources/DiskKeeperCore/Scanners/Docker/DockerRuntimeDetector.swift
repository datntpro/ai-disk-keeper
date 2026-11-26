import Foundation

public enum DockerRuntimeState: Sendable, Hashable {
    case notInstalled
    case notRunning
    case timedOut
    case running(serverVersion: String)

    public var isRunning: Bool { if case .running = self { return true } else { return false } }
}

public struct DockerRuntimeStatus: Sendable, Hashable, Identifiable {
    public let definition: DockerRuntimeDefinition
    public let state: DockerRuntimeState
    public let diskImage: DockerDiskImage?
    public var id: String { definition.id }

    public init(definition: DockerRuntimeDefinition, state: DockerRuntimeState, diskImage: DockerDiskImage?) {
        self.definition = definition; self.state = state; self.diskImage = diskImage
    }
}

/// Shared by the scanner and the module card. Starts a process only when a validated socket exists, and never
/// starts or stops a runtime.
public struct DockerRuntimeDetector: Sendable {
    let layout: DockerRuntimeLayout
    let runner: any ToolProcessRunning
    let resolver: ToolExecutableResolver
    let versionTimeout: Duration

    public init(layout: DockerRuntimeLayout, runner: any ToolProcessRunning = ToolCommandRunner(),
                resolver: ToolExecutableResolver = ToolExecutableResolver(),
                versionTimeout: Duration = DockerProbe.versionTimeout) {
        self.layout = layout
        self.runner = runner
        self.resolver = resolver
        self.versionTimeout = versionTimeout
    }

    public func detect(home: String) async -> [DockerRuntimeStatus] {
        let base = ToolCommandRunner.baseEnvironment(home: home)
        var seenSockets = Set<String>()
        var out: [DockerRuntimeStatus] = []
        for def in layout.runtimes() {
            let socket = layout.validatedSocket(def.socketPath, userID: resolver.userID)
            // Two runtimes behind one socket are one runtime.
            if let socket, !seenSockets.insert(socket).inserted { continue }
            let disk = DockerDiskImage.stat(def.diskImagePaths)
            let cliFound: Bool = { if case .success = resolver.resolve(candidates: def.cliCandidates) { return true } else { return false } }()
            let appFound = def.appBundles.contains { FileManager.default.fileExists(atPath: $0) }
            guard cliFound || socket != nil || appFound || disk != nil else {
                out.append(DockerRuntimeStatus(definition: def, state: .notInstalled, diskImage: nil))
                continue
            }
            guard socket != nil else {
                out.append(DockerRuntimeStatus(definition: def, state: .notRunning, diskImage: disk))
                continue
            }
            guard case .success(let conn) = DockerConnection.open(def, layout: layout, resolver: resolver, baseEnvironment: base) else {
                out.append(DockerRuntimeStatus(definition: def, state: cliFound ? .notRunning : .notInstalled, diskImage: disk))
                continue
            }
            let result = await conn.run(DockerProbe.version, timeout: versionTimeout, runner: runner)
            let state: DockerRuntimeState
            if let result {
                if result.timedOut { state = .timedOut }
                else if result.exitStatus != 0 { state = .notRunning }
                else { state = .running(serverVersion: DockerJSON.serverVersion(result.stdout) ?? "") }
            } else { state = .notRunning }
            out.append(DockerRuntimeStatus(definition: def, state: state, diskImage: disk))
        }
        return out
    }
}
