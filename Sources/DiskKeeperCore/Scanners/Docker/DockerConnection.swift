import Foundation

/// A resolved CLI plus the exact environment it runs with: `DOCKER_HOST` points at the runtime's own validated
/// socket, so the user's current context and `~/.docker/config.json` play no part and nothing goes over the network.
struct DockerConnection: Sendable {
    let executable: URL
    let environment: [String: String]

    enum Failure: Error { case noSocket, noCLI }

    static func open(_ def: DockerRuntimeDefinition, layout: DockerRuntimeLayout, resolver: ToolExecutableResolver,
                     baseEnvironment: [String: String]) -> Result<DockerConnection, Failure> {
        guard let socket = layout.validatedSocket(def.socketPath, userID: resolver.userID) else { return .failure(.noSocket) }
        guard case .success(let exe) = resolver.resolve(candidates: def.cliCandidates) else { return .failure(.noCLI) }
        return .success(DockerConnection(executable: exe, environment: environment(base: baseEnvironment, socket: socket)))
    }

    static func environment(base: [String: String], socket: String) -> [String: String] {
        base.merging(["DOCKER_HOST": "unix://" + socket, "DOCKER_CLI_HINTS": "false"]) { $1 }
    }

    func run(_ argv: [String], timeout: Duration, runner: any ToolProcessRunning,
             maxStdout: Int = ToolCommandRunner.probeStdoutCap) async -> ToolCommandResult? {
        try? await runner.run(executable: executable, arguments: argv, environment: environment, timeout: timeout,
                              maxStdout: maxStdout)
    }
}

/// The complete list of read-only commands. Nothing else is ever run to look at Docker.
public enum DockerProbe {
    static let version = ["version", "--format", "{{json .}}"]
    static let systemDF = ["system", "df", "-v", "--format", "{{json .}}"]
    static let imageList = ["image", "ls", "--no-trunc", "--format", "{{json .}}"]
    static let containerList = ["container", "ls", "--all", "--no-trunc", "--format", "{{json .}}"]
    static let volumeList = ["volume", "ls", "--format", "{{json .}}"]
    static func imageInspect(_ id: String) -> [String] { ["image", "inspect", "--format", "{{.Id}}|{{json .RepoTags}}", id] }
    static func containersUsingImage(_ id: String) -> [String] {
        ["container", "ls", "--all", "--quiet", "--no-trunc", "--filter", "ancestor=" + id]
    }
    static func containerState(_ id: String) -> [String] { ["container", "inspect", "--format", "{{.State.Status}}", id] }
    static func containersUsingVolume(_ name: String) -> [String] {
        ["container", "ls", "--all", "--quiet", "--filter", "volume=" + name]
    }
    static func volumeInspect(_ name: String) -> [String] { ["volume", "inspect", "--format", "{{.Name}}", name] }

    public static let versionTimeout = Duration.seconds(5)
    static let dfTimeout = Duration.seconds(60)
    static let listTimeout = Duration.seconds(30)
    static let inspectTimeout = Duration.seconds(10)
}
