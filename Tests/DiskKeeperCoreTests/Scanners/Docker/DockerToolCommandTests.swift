import XCTest
@testable import DiskKeeperCore

final class DockerToolCommandTests: CleanupTestCase {
    private var h: DockerHome!
    private var world: DockerWorld!
    private let now = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        h = try DockerHome(); world = DockerWorld()
    }

    private func registry() -> ToolCommandRegistry {
        let l = h.layout()
        return ToolCommandRegistry(specs: DockerToolCommands.specs(layout: { _ in l }))
    }
    private func performer() -> ToolCommandPerformer {
        ToolCommandPerformer(registry: registry(), context: ToolCommandContext(environment: h.env, runner: world))
    }
    private func engine() throws -> CleanupEngine {
        CleanupEngine(pathGuard: try makeGuard(), auditLog: AuditLog(fileURL: auditURL),
                      trash: DirectoryTrash(root: trashDir), runningApps: FakeRunningApps(), toolCommands: performer())
    }
    private func scanItems() async throws -> [ScanItem] {
        let l = h.layout()
        let scanner = DockerScanner(layout: { _ in l }, runner: world)
        let ctx = ScanContext(environment: h.env, pathGuard: try ScanGuard(environment: h.env, protectPatterns: []), now: now)
        let box = ItemBox()
        try await scanner.scan(context: ctx, sink: ScanSink(item: { await box.add($0) }, warning: { _ in }, progress: { _ in }))
        return await box.items
    }
    private actor ItemBox { var items: [ScanItem] = []; func add(_ i: ScanItem) { items.append(i) } }
    private func item(_ suffix: String) async throws -> ScanItem {
        let all = try await scanItems()
        return try XCTUnwrap(all.first { $0.path.hasSuffix(suffix) })
    }

    // MARK: Registry

    func testEveryScannedActionableItemMatchesItsSpec() async throws {
        for i in try await scanItems() where i.cleanupMethod != .none {
            switch registry().match(i, environment: h.env) {
            case .success(let m): XCTAssertEqual(m.argv, { if case .toolCommand(_, let a) = i.cleanupMethod { return a } else { return [] } }(), i.path)
            case .failure(let r): XCTFail("\(i.path): \(r.reason)")
            }
        }
    }

    func testRefusals() throws {
        let id = "sha256:" + DockerWorld.a
        func make(_ args: [String], rule: String = DockerToolCommands.Rule.dangling, kind: String = "image", pid: String = id) -> ScanItem {
            let path = VirtualItemPath.build(namespace: "docker", target: "docker-desktop", kind: kind, id: pid)!
            return ScanItem(url: URL(fileURLWithPath: path), displayName: "x", tool: .docker, category: .docker, sizeAllocated: 1,
                            sizeLogical: 1, fileCount: 0, lastModified: nil, tier: .review, explanation: "", ruleID: rule,
                            cleanupMethod: .toolCommand(command: "docker", arguments: args))
        }
        let r = registry()
        func refused(_ i: ScanItem, _ why: String) {
            if case .success = r.match(i, environment: h.env) { XCTFail(why) }
        }
        XCTAssertNoThrow(try r.match(make(["image", "rm", id]), environment: h.env).get())
        refused(make(["image", "rm", "--force", id]), "force")
        refused(make(["image", "rm", "-f", id]), "-f")
        refused(make(["system", "prune"]), "prune")
        refused(make(["image", "rm", id, "extra"]), "extra arg for dangling (binding)")
        refused(make(["image", "rm", "sha256:" + DockerWorld.b]), "args name another image")
        refused(make(["image", "rm"] + (0..<9).map { "r\($0):1" }, rule: DockerToolCommands.Rule.unusedImage), "9 refs")
        refused(make(["image", "rm", "a b:1"], rule: DockerToolCommands.Rule.unusedImage), "space")
        refused(make(["image", "rm", "a@sha256:abc"], rule: DockerToolCommands.Rule.unusedImage), "@")
        refused(make(["volume", "rm", "-bad"], rule: DockerToolCommands.Rule.anonymousVolume, kind: "volume", pid: "-bad"), "leading dash volume")
        refused(make(["container", "rm", String(repeating: "e", count: 12)], rule: DockerToolCommands.Rule.container, kind: "container", pid: String(repeating: "e", count: 12)), "12-hex container")
        refused(make(["container", "rm", "-v", DockerWorld.stopped], rule: DockerToolCommands.Rule.container, kind: "container", pid: DockerWorld.stopped), "-v")
        refused(make(["image", "rm", id], rule: "rule.json.thing"), "json rule id")
        refused(make(["builder", "prune", "--all", "--force", "--filter", "x"], rule: DockerToolCommands.Rule.buildCache, kind: "buildcache", pid: "all"), "extra filter")
        XCTAssertNoThrow(try r.match(make(["builder", "prune", "--all", "--force"], rule: DockerToolCommands.Rule.buildCache, kind: "buildcache", pid: "all"), environment: h.env).get())
    }

    func testForbiddenTokenLint() {
        let forbidden: Set<String> = ["system", "network", "compose", "run", "exec", "start", "stop", "kill", "context", "login", "-f", "-v", "--filter"]
        for t in DockerToolCommands.allLiteralTokens { XCTAssertFalse(forbidden.contains(t), t) }
        for s in DockerToolCommands.specs() {
            for case .literal(let t) in s.template where t == "--force" { XCTAssertEqual(s.id, "docker.builder.prune") }
            for case .literal(let t) in s.template where t == "prune" { XCTAssertEqual(s.id, "docker.builder.prune") }
            XCTAssertTrue(s.ruleIDs.allSatisfy { $0.hasPrefix("tool.") })
        }
    }

    func testEnvironmentIsExact() async throws {
        let i = try await item("sha256:" + DockerWorld.a)
        let spec = try XCTUnwrap(registry().specs.first { $0.id == "docker.image.rm" })
        let ctx = ToolCommandContext(environment: h.env, runner: world)
        let env = try XCTUnwrap(spec.environment(ctx, i))
        let real = String(cString: realpath(h.socket, nil))
        XCTAssertEqual(env, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": h.home,
                             "DOCKER_HOST": "unix://" + real, "DOCKER_CLI_HINTS": "false"])
    }

    // MARK: Engine

    func testPlanThenExecuteRunsExactlyTheShownArgv() async throws {
        let i = try await item("sha256:" + DockerWorld.a)
        let eng = try engine()
        let plan = await eng.plan([i])
        let e = plan.entries[0]
        XCTAssertTrue(e.isExecutable, "\(e.blockers)")
        let snap = try XCTUnwrap(e.toolCommand)
        XCTAssertEqual(ToolCommandDisplay.line(snap), "docker image rm sha256:" + DockerWorld.a)
        XCTAssertTrue(world.destructive.isEmpty)
        let report = try await eng.execute(plan)
        guard case .ranCommand(0) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(world.destructive, [["image", "rm", "sha256:" + DockerWorld.a]])
        XCTAssertEqual(world.destructive[0], snap.argv)
        let rec = try XCTUnwrap(AuditLog.read(auditURL).first)
        XCTAssertEqual(rec.result, "ran"); XCTAssertEqual(rec.exitStatus, 0); XCTAssertEqual(rec.toolTarget, "docker-desktop")
        XCTAssertEqual(rec.command?.last, "sha256:" + DockerWorld.a); XCTAssertEqual(rec.command?.dropLast(3).count, 1)
        XCTAssertEqual(report.freedBytes, 10_000_000)
    }

    func testEveryKindRunsItsOwnCommandOnly() async throws {
        let items = try await scanItems().filter { $0.cleanupMethod != .none && $0.tier == .review || $0.tier == .safe }
        let eng = try engine()
        let plan = await eng.plan(items)
        XCTAssertTrue(plan.entries.allSatisfy(\.isExecutable), "\(plan.entries.map(\.blockers))")
        _ = try await eng.execute(plan)
        let argv = Set(world.destructive.map { $0.joined(separator: " ") })
        XCTAssertTrue(argv.contains("builder prune --all --force"))
        XCTAssertTrue(argv.contains("image rm app:1 app:latest"))
        XCTAssertTrue(argv.contains("container rm " + DockerWorld.stopped))
        XCTAssertTrue(argv.contains("volume rm " + DockerWorld.anon))
        XCTAssertFalse(argv.contains { $0.contains("--force") && !$0.hasPrefix("builder prune") })
    }

    func testContainerAppearsBetweenPlanAndExecute() async throws {
        let i = try await item("sha256:" + DockerWorld.b)
        let eng = try engine()
        let plan = await eng.plan([i])
        XCTAssertTrue(plan.entries[0].isExecutable)
        world.extraContainerForImage = "sha256:" + DockerWorld.b
        let report = try await eng.execute(plan)
        XCTAssertEqual(skippedCodes(report.results[0].outcome), ["inUseByTool"])
        XCTAssertTrue(world.destructive.isEmpty)
    }

    func testImageGoneIsMissingAndDaemonDownNotRunning() async throws {
        let i = try await item("sha256:" + DockerWorld.a)
        let eng = try engine()
        let plan = await eng.plan([i])
        world.removed.insert("sha256:" + DockerWorld.a)
        let r1 = try await eng.execute(plan)
        XCTAssertEqual(skippedCodes(r1.results[0].outcome), ["missing"])
        world.removed = []
        let plan2 = await eng.plan([i])
        world.up = false
        let r2 = try await eng.execute(plan2)
        XCTAssertEqual(skippedCodes(r2.results[0].outcome), ["toolNotRunning"])
        XCTAssertTrue(world.destructive.isEmpty)
    }

    func testTagsChangedBlocks() async throws {
        let i = try await item("sha256:" + DockerWorld.a)   // dangling, inspect says no tags
        var tagged = i; tagged.cleanupMethod = i.cleanupMethod
        let eng = try engine()
        let plan = await eng.plan([i])
        XCTAssertTrue(plan.entries[0].isExecutable)
        // A tagged image whose method lists a different tag set than docker reports.
        var wrong = try await item("sha256:" + DockerWorld.b)
        wrong.cleanupMethod = .toolCommand(command: "docker", arguments: ["image", "rm", "app:1"])
        let p2 = await eng.plan([wrong])
        XCTAssertEqual(p2.entries[0].blockers.map(\.code), ["inUseByTool"])
    }

    func testDigestOnlyImagePlansExecutableAndRemovesByID() async throws {
        let id = "sha256:" + DockerWorld.digestOnly
        let i = try await item(id)
        let eng = try engine()
        let plan = await eng.plan([i])
        XCTAssertTrue(plan.entries[0].isExecutable, "\(plan.entries[0].blockers)")
        let report = try await eng.execute(plan)
        guard case .ranCommand = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertEqual(world.destructive, [["image", "rm", id]])
    }

    func testConflictFailsWithReasonAndAuditsStderr() async throws {
        let i = try await item("sha256:" + DockerWorld.a)
        let eng = try engine()
        let plan = await eng.plan([i])
        world.failRm = "Error response from daemon: conflict: unable to delete"
        let report = try await eng.execute(plan)
        guard case .failed(let why) = report.results[0].outcome else { return XCTFail("\(report.results[0].outcome)") }
        XCTAssertTrue(why.contains("docker exited 1") && why.contains("conflict"))
        XCTAssertNotNil(try AuditLog.read(auditURL).first?.stderrTail)
    }

    func testKeepNamedVolumeIsNotActionable() async throws {
        let i = try await item("/pgdata")
        XCTAssertEqual(i.tier, .keep)
        let plan = await (try engine()).plan([i])
        XCTAssertFalse(plan.entries[0].isExecutable)
        XCTAssertTrue(world.destructive.isEmpty)
    }
}

/// Tests never touch a host runtime.
final class DockerNoHostAccessLintTests: XCTestCase {
    func testTestsNeverUseLiveLayoutOrHostPaths() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let me = #filePath
        let needles = ["DockerRuntimeLayout" + ".live", "/usr/local/bin/" + "docker", ".docker/" + "run", ".orb" + "stack", ".col" + "ima"]
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where f.pathExtension == "swift" && f.path != me {
            let text = try String(contentsOf: f, encoding: .utf8)
            for n in needles where n != ".docker/" + "run" { XCTAssertFalse(text.contains(n), "\(f.lastPathComponent) mentions \(n)") }
        }
    }
}
