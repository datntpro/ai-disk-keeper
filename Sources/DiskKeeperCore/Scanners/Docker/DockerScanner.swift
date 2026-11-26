import Foundation

/// Reads images, containers, volumes and build cache from every running Docker-compatible runtime, through the
/// runtime's own CLI and validated socket. Read-only; never starts a runtime; never touches the VM disk image.
public struct DockerScanner: Scanner {
    public let id = "docker"
    public var virtualNamespace: String? { "docker" }

    let layout: DockerToolCommands.LayoutProvider
    let runner: any ToolProcessRunning
    let resolver: ToolExecutableResolver
    let budget: Duration
    let versionTimeout: Duration

    public init(layout: @escaping DockerToolCommands.LayoutProvider = { DockerRuntimeLayout.live(environment: $0) },
                runner: any ToolProcessRunning = ToolCommandRunner(), resolver: ToolExecutableResolver = ToolExecutableResolver(),
                budget: Duration = .seconds(90), versionTimeout: Duration = DockerProbe.versionTimeout) {
        self.layout = layout
        self.runner = runner
        self.resolver = resolver
        self.budget = budget
        self.versionTimeout = versionTimeout
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        let layout = layout(context.environment)
        let detector = DockerRuntimeDetector(layout: layout, runner: runner, resolver: resolver, versionTimeout: versionTimeout)
        let statuses = await detector.detect(home: context.environment.home)
        try Task.checkCancellation()
        let running = statuses.filter { $0.state.isRunning }
        let base = ToolCommandRunner.baseEnvironment(home: context.environment.home)
        let deadline = ContinuousClock.now.advanced(by: budget)
        var progress = ScannerProgress()
        for status in statuses where status.state == .timedOut {
            await sink.warning(warning(status.definition, timeout: true))
        }
        for status in running {
            try Task.checkCancellation()
            guard case .success(let conn) = DockerConnection.open(status.definition, layout: layout, resolver: resolver, baseEnvironment: base) else { continue }
            let timedOut = TimeoutFlag()
            guard let inputs = await read(conn, deadline: deadline, timedOut: timedOut) else {
                await sink.warning(warning(status.definition, timeout: timedOut.value))
                continue
            }
            let factory = DockerItemFactory(target: status.definition.id, runtimeName: status.definition.displayName,
                                            suffixRuntime: running.count > 1, now: context.now)
            let all = factory.items(inputs)
            for item in all {
                progress.candidatesFound += 1; progress.candidatesSized += 1; progress.bytesFound += item.sizeAllocated
                await sink.item(item)
            }
            if inputs.images.count + inputs.containers.count + inputs.volumes.count > DockerItemFactory.maxItems * 2 {
                await sink.warning(ScanWarning(kind: .other, message: "\(status.definition.displayName) has more than \(DockerItemFactory.maxItems) cleanable objects; showing the largest.",
                                               code: .itemCapExceeded(cap: DockerItemFactory.maxItems)))
            }
            await sink.progress(progress)
        }
    }

    /// R2–R5 sequentially under one budget. nil on any failure, timeout or malformed output.
    private func read(_ conn: DockerConnection, deadline: ContinuousClock.Instant, timedOut: TimeoutFlag) async -> DockerItemFactory.Inputs? {
        func run(_ argv: [String], _ timeout: Duration) async -> Data? {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { timedOut.value = true; return nil }
            guard let r = await conn.run(argv, timeout: min(timeout, left), runner: runner) else { return nil }
            if r.timedOut { timedOut.value = true; return nil }
            guard r.exitStatus == 0 else { return nil }
            return r.stdout
        }
        guard let dfData = await run(DockerProbe.systemDF, DockerProbe.dfTimeout), let df = DockerJSON.parseDF(dfData),
              let imgData = await run(DockerProbe.imageList, DockerProbe.listTimeout), let images = DockerJSON.parseImages(imgData),
              let cData = await run(DockerProbe.containerList, DockerProbe.listTimeout), let containers = DockerJSON.parseContainers(cData),
              let vData = await run(DockerProbe.volumeList, DockerProbe.listTimeout), let volumes = DockerJSON.parseVolumes(vData)
        else { return nil }
        return .init(df: df, images: images, containers: containers, volumes: volumes)
    }

    private func warning(_ def: DockerRuntimeDefinition, timeout: Bool) -> ScanWarning {
        ScanWarning(kind: timeout ? .timeout : .scannerFailed,
                    message: timeout ? "\(def.displayName) didn't respond in time." : "Couldn't read \(def.displayName).",
                    code: .scannerFailed(scannerID: "docker"))
    }
}

private final class TimeoutFlag: @unchecked Sendable { var value = false }
