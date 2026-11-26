import Foundation

/// The complete list of Docker commands that may remove anything. Nothing else is ever run to clean up.
/// Every spec binds its argv to the item's identity and re-checks the object right before it runs.
/// Never in any spec: `system|image|container|volume|network prune`, `-f`/`--force` on `rm`, `-v` on `container rm`,
/// `compose`, `run`, `exec`, `start`, `stop`, `kill`, `context`, `login`, variable `--filter` values.
public enum DockerToolCommands {
    public typealias LayoutProvider = @Sendable (PathEnvironment) -> DockerRuntimeLayout

    public enum Rule {
        public static let dangling = "tool.docker.image.dangling"
        public static let unusedImage = "tool.docker.image.unused"
        public static let container = "tool.docker.container.stopped"
        public static let anonymousVolume = "tool.docker.volume.anonymous"
        public static let namedVolume = "tool.docker.volume.named"
        public static let buildCache = "tool.docker.buildcache"
    }

    public static func specs(layout: @escaping LayoutProvider = { DockerRuntimeLayout.live(environment: $0) }) -> [ToolCommandSpec] {
        let live = Env(layout: layout)
        return [
            ToolCommandSpec(
                id: "docker.image.rm", command: "docker", ruleIDs: [Rule.dangling, Rule.unusedImage],
                target: .virtual(namespace: "docker"),
                template: [.literal("image"), .literal("rm"), .params(.dockerImageRef, max: 8)],
                bind: { item in
                    guard let p = VirtualItemPath.parse(item.path), p.kind == "image", ArgPattern.dockerImageID.matches(p.id) else { return nil }
                    if item.ruleID == Rule.dangling { return ["image", "rm", p.id] }
                    guard case .toolCommand(_, let args) = item.cleanupMethod, args.count >= 3, args.count <= 10,
                          args[0] == "image", args[1] == "rm" else { return nil }
                    let refs = Array(args.dropFirst(2))
                    return refs.allSatisfy({ ArgPattern.dockerImageRef.matches($0) && $0 != p.id }) ? ["image", "rm"] + refs : nil
                },
                timeout: .seconds(120), executable: live.executable, environment: live.environment,
                revalidate: { ctx, item in await live.revalidateImage(ctx, item) }),
            ToolCommandSpec(
                id: "docker.container.rm", command: "docker", ruleIDs: [Rule.container], target: .virtual(namespace: "docker"),
                template: [.literal("container"), .literal("rm"), .param(.dockerContainerID)],
                bind: { item in
                    guard let p = VirtualItemPath.parse(item.path), p.kind == "container" else { return nil }
                    return ["container", "rm", p.id]
                },
                timeout: .seconds(60), executable: live.executable, environment: live.environment,
                revalidate: { ctx, item in await live.revalidateContainer(ctx, item) }),
            ToolCommandSpec(
                id: "docker.volume.rm", command: "docker", ruleIDs: [Rule.anonymousVolume], target: .virtual(namespace: "docker"),
                template: [.literal("volume"), .literal("rm"), .param(.dockerVolumeName)],
                bind: { item in
                    guard let p = VirtualItemPath.parse(item.path), p.kind == "volume" else { return nil }
                    return ["volume", "rm", p.id]
                },
                timeout: .seconds(60), executable: live.executable, environment: live.environment,
                revalidate: { ctx, item in await live.revalidateVolume(ctx, item) }),
            ToolCommandSpec(
                id: "docker.builder.prune", command: "docker", ruleIDs: [Rule.buildCache], target: .virtual(namespace: "docker"),
                template: [.literal("builder"), .literal("prune"), .literal("--all"), .literal("--force")],
                // `--force` only skips the y/N prompt, which would otherwise read /dev/null. Docker prunes only
                // cache that no build is using.
                bind: { item in
                    guard let p = VirtualItemPath.parse(item.path), p.kind == "buildcache" else { return nil }
                    return ["builder", "prune", "--all", "--force"]
                },
                timeout: .seconds(15 * 60), executable: live.executable, environment: live.environment,
                revalidate: { ctx, item in await live.revalidateRunning(ctx, item) }),
        ]
    }

    /// Every literal argv token of every destructive spec and read probe (for the forbidden-token lint).
    static var allLiteralTokens: [String] {
        specs().flatMap { $0.template.compactMap { if case .literal(let s) = $0 { return s } else { return nil } } }
    }

    // MARK: Closures shared by the specs

    private struct Env: Sendable {
        let layout: LayoutProvider
        var resolver: ToolExecutableResolver { ToolExecutableResolver() }

        private func definition(_ ctx: ToolCommandContext, _ item: ScanItem) -> (DockerRuntimeDefinition, DockerRuntimeLayout)? {
            guard let target = VirtualItemPath.parse(item.path)?.target else { return nil }
            let l = layout(ctx.environment)
            return l.runtime(id: target).map { ($0, l) }
        }

        var executable: @Sendable (ToolCommandContext, ScanItem) -> ExecutableChoice {
            { ctx, item in ExecutableChoice(candidates: definition(ctx, item)?.0.cliCandidates ?? []) }
        }

        var environment: @Sendable (ToolCommandContext, ScanItem) -> [String: String]? {
            { ctx, item in
                guard let (def, l) = definition(ctx, item),
                      let socket = l.validatedSocket(def.socketPath, userID: resolver.userID) else { return nil }
                return DockerConnection.environment(base: ctx.baseEnvironment, socket: socket)
            }
        }

        private enum Connected { case ok(DockerConnection), blocked([CleanupBlocker]) }

        /// Daemon reachable? One `version` per target while planning (the cache), always fresh at execute.
        private func connect(_ ctx: ToolCommandContext, _ item: ScanItem) async -> Connected {
            let target = VirtualItemPath.parse(item.path)?.target ?? ""
            guard let (def, l) = definition(ctx, item) else { return .blocked([.toolNotRunning(tool: "docker", target: target)]) }
            switch DockerConnection.open(def, layout: l, resolver: resolver, baseEnvironment: ctx.baseEnvironment) {
            case .failure(.noSocket): return .blocked([.toolNotRunning(tool: "docker", target: target)])
            case .failure(.noCLI): return .blocked([.toolUnavailable(tool: "docker")])
            case .success(let conn):
                let key = "docker.version|" + target
                if let cached = ctx.probes?.value(key, as: Bool.self) {
                    return cached ? .ok(conn) : .blocked([.toolNotRunning(tool: "docker", target: target)])
                }
                let r = await conn.run(DockerProbe.version, timeout: DockerProbe.versionTimeout, runner: ctx.runner,
                                       maxStdout: ToolCommandRunner.probeStdoutCap)
                let up = r.map { !$0.timedOut && $0.exitStatus == 0 } ?? false
                ctx.probes?.store(key, up)
                return up ? .ok(conn) : .blocked([.toolNotRunning(tool: "docker", target: target)])
            }
        }

        func revalidateRunning(_ ctx: ToolCommandContext, _ item: ScanItem) async -> [CleanupBlocker] {
            if case .blocked(let b) = await connect(ctx, item) { return b }
            return []
        }

        private func probe(_ conn: DockerConnection, _ ctx: ToolCommandContext, _ argv: [String]) async -> ToolCommandResult? {
            await conn.run(argv, timeout: DockerProbe.inspectTimeout, runner: ctx.runner)
        }

        func revalidateImage(_ ctx: ToolCommandContext, _ item: ScanItem) async -> [CleanupBlocker] {
            let conn: DockerConnection
            switch await connect(ctx, item) { case .blocked(let b): return b; case .ok(let c): conn = c }
            guard let p = VirtualItemPath.parse(item.path), ArgPattern.dockerImageID.matches(p.id),
                  let inspect = await probe(conn, ctx, DockerProbe.imageInspect(p.id)) else { return [.inUseByTool(detail: "couldn't check the image")] }
            guard !inspect.timedOut else { return [.inUseByTool(detail: "couldn't check the image")] }
            guard inspect.exitStatus == 0 else { return [.missing] }
            let text = String(decoding: inspect.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bar = text.firstIndex(of: "|") else { return [.inUseByTool(detail: "couldn't check the image")] }
            guard String(text[..<bar]) == p.id else { return [.missing] }
            let tags = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: bar)...].utf8)) as? [String]) ?? []
            let expected: [String]
            if item.ruleID == Rule.dangling { expected = [] }
            else if case .toolCommand(_, let args) = item.cleanupMethod { expected = Array(args.dropFirst(2)) }
            else { expected = [] }
            guard Set(tags) == Set(expected) else { return [.inUseByTool(detail: "tags changed")] }
            guard let users = await probe(conn, ctx, DockerProbe.containersUsingImage(p.id)), !users.timedOut, users.exitStatus == 0 else {
                return [.inUseByTool(detail: "couldn't check containers")]
            }
            return users.stdout.isEmpty ? [] : [.inUseByTool(detail: "a container uses this image")]
        }

        func revalidateContainer(_ ctx: ToolCommandContext, _ item: ScanItem) async -> [CleanupBlocker] {
            let conn: DockerConnection
            switch await connect(ctx, item) { case .blocked(let b): return b; case .ok(let c): conn = c }
            guard let p = VirtualItemPath.parse(item.path), ArgPattern.dockerContainerID.matches(p.id),
                  let r = await probe(conn, ctx, DockerProbe.containerState(p.id)), !r.timedOut else {
                return [.inUseByTool(detail: "couldn't check the container")]
            }
            guard r.exitStatus == 0 else { return [.missing] }
            let state = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ["exited", "created", "dead"].contains(state) ? [] : [.inUseByTool(detail: "container is \(state)")]
        }

        func revalidateVolume(_ ctx: ToolCommandContext, _ item: ScanItem) async -> [CleanupBlocker] {
            let conn: DockerConnection
            switch await connect(ctx, item) { case .blocked(let b): return b; case .ok(let c): conn = c }
            guard let p = VirtualItemPath.parse(item.path), ArgPattern.dockerVolumeName.matches(p.id),
                  let exists = await probe(conn, ctx, DockerProbe.volumeInspect(p.id)), !exists.timedOut else {
                return [.inUseByTool(detail: "couldn't check the volume")]
            }
            guard exists.exitStatus == 0 else { return [.missing] }
            guard let users = await probe(conn, ctx, DockerProbe.containersUsingVolume(p.id)), !users.timedOut, users.exitStatus == 0 else {
                return [.inUseByTool(detail: "couldn't check containers")]
            }
            return users.stdout.isEmpty ? [] : [.inUseByTool(detail: "a container uses this volume")]
        }
    }
}
