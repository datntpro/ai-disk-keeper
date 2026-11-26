import Darwin
import XCTest
@testable import DiskKeeperCore

final class DockerSizeTests: XCTestCase {
    func testTable() {
        let cases: [(String, Int64?)] = [("2B (virtual 72.8MB)", 2), ("0B", 0), ("1.5kB", 1500), ("1.5KB", 1500), ("72.8MB", 72_800_000),
                                         ("1.5GB", 1_500_000_000), ("2TB", 2_000_000_000_000), ("1KiB", 1024), ("1MiB", 1_048_576),
                                         ("1GiB", 1_073_741_824), ("N/A", nil), ("", nil), ("-5MB", nil), ("12XB", nil), ("abc", nil)]
        for (text, want) in cases { XCTAssertEqual(DockerSize.parse(text), want, text) }
    }
}

final class DockerScannerTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!

    private func scan(_ h: DockerHome, _ world: DockerWorld, layout: DockerRuntimeLayout? = nil,
                      budget: Duration = .seconds(90)) async throws -> (items: [ScanItem], warnings: [ScanWarning]) {
        let l = layout ?? h.layout()
        let scanner = DockerScanner(layout: { _ in l }, runner: world, budget: budget)
        let guardian = try ScanGuard(environment: h.env, protectPatterns: [])
        let ctx = ScanContext(environment: h.env, pathGuard: guardian, now: now)
        let box = Box()
        try await scanner.scan(context: ctx, sink: ScanSink(item: { await box.add($0) }, warning: { await box.warn($0) }, progress: { _ in }))
        return await (box.items, box.warnings)
    }
    private actor Box { var items: [ScanItem] = []; var warnings: [ScanWarning] = []
        func add(_ i: ScanItem) { items.append(i) }; func warn(_ w: ScanWarning) { warnings.append(w) } }

    func testTiersAndMethods() async throws {
        let h = try DockerHome(); let w = DockerWorld()
        let (items, warnings) = try await scan(h, w)
        XCTAssertTrue(warnings.isEmpty)
        func one(_ rule: String, _ id: String? = nil) -> ScanItem? { items.first { $0.ruleID == rule && (id == nil || $0.path.hasSuffix(id!)) } }
        let dangling = try XCTUnwrap(items.first { $0.path.hasSuffix("sha256:" + DockerWorld.a) })
        XCTAssertEqual(dangling.tier, .safe)
        XCTAssertEqual(dangling.cleanupMethod, .toolCommand(command: "docker", arguments: ["image", "rm", "sha256:" + DockerWorld.a]))
        XCTAssertEqual(dangling.sizeAllocated, 10_000_000)
        XCTAssertEqual(try XCTUnwrap(items.first { $0.path.hasSuffix("sha256:" + DockerWorld.d) }).tier, .review, "dangling < 1 h old")
        let tagged = try XCTUnwrap(items.first { $0.path.hasSuffix("sha256:" + DockerWorld.b) })
        XCTAssertEqual(tagged.tier, .review)
        XCTAssertEqual(tagged.cleanupMethod, .toolCommand(command: "docker", arguments: ["image", "rm", "app:1", "app:latest"]))
        XCTAssertEqual(tagged.displayName, "app:1 (+1 tags)")
        XCTAssertNil(items.first { $0.path.hasSuffix("sha256:" + DockerWorld.c) }, "image used only by a stopped container")
        let container = try XCTUnwrap(one(DockerToolCommands.Rule.container))
        XCTAssertEqual(container.tier, .review); XCTAssertEqual(container.displayName, "old-web · web:1")
        XCTAssertNil(items.first { $0.path.hasSuffix(DockerWorld.running) }, "running container is never an item")
        XCTAssertEqual(try XCTUnwrap(one(DockerToolCommands.Rule.anonymousVolume)).tier, .review)
        let named = try XCTUnwrap(one(DockerToolCommands.Rule.namedVolume))
        XCTAssertEqual(named.tier, .keep); XCTAssertEqual(named.cleanupMethod, .none)
        XCTAssertNil(items.first { $0.path.hasSuffix("/inuse") })
        let cache = items.filter { $0.ruleID == DockerToolCommands.Rule.buildCache }
        XCTAssertEqual(cache.count, 1); XCTAssertEqual(cache[0].tier, .safe); XCTAssertEqual(cache[0].sizeAllocated, 3_000_000)
        XCTAssertEqual(items.filter { $0.tier == .safe }.map(\.ruleID).sorted(),
                       [DockerToolCommands.Rule.buildCache, DockerToolCommands.Rule.dangling])
        for i in items {
            XCTAssertNotNil(VirtualItemPath.parse(i.path)); XCTAssertTrue(i.ruleID.hasPrefix("tool."))
            XCTAssertFalse(i.path.contains("com.docker.docker")); XCTAssertEqual(i.category, .docker)
            XCTAssertNotNil(DockerItemFactory.explanations[i.ruleID])
        }
        let argv = w.calls.map { $0.joined(separator: " ") }
        XCTAssertTrue(w.destructive.isEmpty, "\(argv)")
        let allowed: Set<[String]> = [DockerProbe.version, DockerProbe.systemDF, DockerProbe.imageList, DockerProbe.containerList, DockerProbe.volumeList]
        XCTAssertTrue(w.calls.allSatisfy { allowed.contains($0) }, "\(argv)")
    }

    func testNotRunningAndNotInstalledAreSilent() async throws {
        let h = try DockerHome(socket: false); let w = DockerWorld()
        let r = try await scan(h, w)
        XCTAssertTrue(r.items.isEmpty); XCTAssertTrue(r.warnings.isEmpty)
        XCTAssertTrue(w.calls.isEmpty, "a missing socket launches no process")
        let none = try DockerHome(socket: false, cli: false)
        let r2 = try await scan(none, DockerWorld())
        XCTAssertTrue(r2.items.isEmpty && r2.warnings.isEmpty)
    }

    func testDaemonDownVersionFailsSilently() async throws {
        let h = try DockerHome(); let w = DockerWorld(); w.up = false
        let r = try await scan(h, w)
        XCTAssertTrue(r.items.isEmpty); XCTAssertTrue(r.warnings.isEmpty)
        XCTAssertEqual(w.calls, [DockerProbe.version])
    }

    func testListTimeoutBecomesOneWarning() async throws {
        let h = try DockerHome(); let w = DockerWorld(); w.hangOn = "image ls"
        let r = try await scan(h, w)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.warnings.count, 1); XCTAssertEqual(r.warnings[0].kind, .timeout)
        XCTAssertEqual(r.warnings[0].code, .scannerFailed(scannerID: "docker"))
        XCTAssertFalse(r.warnings[0].message.contains("boom"))
    }

    func testMalformedJSONBecomesOneWarning() async throws {
        let h = try DockerHome(); let w = DockerWorld(); w.dfOverride = "not json"
        let r = try await scan(h, w)
        XCTAssertTrue(r.items.isEmpty); XCTAssertEqual(r.warnings.count, 1); XCTAssertEqual(r.warnings[0].kind, .scannerFailed)
    }

    func testVersionTimeoutWarns() async throws {
        let h = try DockerHome(); let w = DockerWorld(); w.hangOn = "version"
        let r = try await scan(h, w)
        XCTAssertEqual(r.warnings.map(\.kind), [.timeout]); XCTAssertTrue(r.items.isEmpty)
    }

    func testTwoRuntimesGetDistinctIDsAndSuffix() async throws {
        let h = try DockerHome()
        let second = try DockerHome()   // a second socket
        let defs = [h.definition(), DockerRuntimeDefinition(id: "orbstack", displayName: "OrbStack", cliCandidates: [h.cli], socketPath: second.socket)]
        let r = try await scan(h, DockerWorld(), layout: DockerRuntimeLayout(home: h.home) { defs })
        let ids = r.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(r.items.contains { $0.displayName.hasSuffix(" · OrbStack") })
        _ = second
    }

    func testUnknownKeysBadRecordsAndTruncatedIDJoins() {
        XCTAssertEqual(DockerJSON.parseImages(Data("{\"ID\":\"sha256:\(DockerWorld.a)\",\"X\":1}\nnot json\n{\"nope\":1}".utf8))?.count, 1)
        XCTAssertNil(DockerJSON.parseImages(Data("garbage".utf8)))
        XCTAssertEqual(DockerJSON.parseImages(Data())?.count, 0, "an empty daemon")
        let df = DockerJSON.parseDF(Data(#"{"Images":[{"ID":"abc","Containers":"0","UniqueSize":"N/A","Size":"N/A"}],"Volumes":[],"BuildCache":[]}"#.utf8))
        XCTAssertEqual(df?.images.first?.size, nil)
    }

    func testAmbiguousTruncatedIDSkipsObject() {
        let f = DockerItemFactory(target: "t", runtimeName: "T", suffixRuntime: false, now: Date())
        var df = DockerJSON.DF(); df.images = [.init(id: "aaaa", containers: 0, size: 1)]
        let rows: [DockerJSON.ImageRow] = ["a" + String(repeating: "1", count: 63), "a" + String(repeating: "2", count: 63)].map {
            .init(id: "sha256:" + $0, repository: "<none>", tag: "<none>", created: nil) }
        XCTAssertTrue(f.items(.init(df: df, images: rows, containers: [], volumes: [])).isEmpty)
        // No df match: skipped too.
        XCTAssertTrue(f.items(.init(df: DockerJSON.DF(), images: [rows[0]], containers: [], volumes: [])).isEmpty)
    }

    func testItemCap() {
        let f = DockerItemFactory(target: "t", runtimeName: "T", suffixRuntime: false, now: Date())
        var df = DockerJSON.DF(); var rows: [DockerJSON.ImageRow] = []
        for n in 0..<1000 {
            let id = String(format: "%064x", n)
            df.images.append(.init(id: id, containers: 0, size: Int64(n)))
            rows.append(.init(id: "sha256:" + id, repository: "<none>", tag: "<none>", created: nil))
        }
        let items = f.items(.init(df: df, images: rows, containers: [], volumes: []))
        XCTAssertEqual(items.count, 500); XCTAssertEqual(items.first?.sizeAllocated, 999)
    }
}

final class DockerRuntimeDetectorTests: XCTestCase {
    private func detect(_ h: DockerHome, _ w: DockerWorld, _ l: DockerRuntimeLayout? = nil) async -> [DockerRuntimeStatus] {
        await DockerRuntimeDetector(layout: l ?? h.layout(), runner: w, versionTimeout: .seconds(1)).detect(home: h.home)
    }

    func testRunning() async throws {
        let h = try DockerHome(); let w = DockerWorld()
        let s = await detect(h, w)
        XCTAssertEqual(s.map(\.state), [.running(serverVersion: "27.0.1")])
        let env = try XCTUnwrap(w.calls.first); XCTAssertEqual(env, DockerProbe.version)
    }

    func testRegularFileNamedSockIsNotASocket() async throws {
        let h = try DockerHome(socket: false)
        FileManager.default.createFile(atPath: h.socket, contents: Data())
        let w = DockerWorld()
        let s = await detect(h, w)
        XCTAssertEqual(s.map(\.state), [.notRunning]); XCTAssertTrue(w.calls.isEmpty)
    }

    func testSymlinkedSocketOutsideHomeRefused() async throws {
        let outside = try DockerHome()          // a real socket, in another tree
        let h = try DockerHome(socket: false)
        symlink(outside.socket, h.socket)
        let w = DockerWorld()
        let s = await detect(h, w)
        XCTAssertEqual(s.map(\.state), [.notRunning]); XCTAssertTrue(w.calls.isEmpty)
    }

    func testVersionFailureIsNotRunningAndHangIsTimedOut() async throws {
        let h = try DockerHome(); let w = DockerWorld(); w.up = false
        let down = await detect(h, w)
        XCTAssertEqual(down.map(\.state), [.notRunning])
        let w2 = DockerWorld(); w2.hangOn = "version"
        let hung = await detect(h, w2)
        XCTAssertEqual(hung.map(\.state), [.timedOut])
    }

    func testSharedSocketCountsOnce() async throws {
        let h = try DockerHome()
        let defs = [h.definition(), h.definition(id: "orbstack", name: "OrbStack")]
        let s = await detect(h, DockerWorld(), h.layout(defs))
        XCTAssertEqual(s.count, 1)
    }

    func testDiskImageSizesFromSparseFileAndNothingIsModified() async throws {
        let h = try DockerHome(); let disk = h.home + "/Docker.raw"
        let fd = open(disk, O_CREAT | O_WRONLY, 0o600); ftruncate(fd, 8 << 30)
        _ = write(fd, [UInt8](repeating: 1, count: 1 << 20), 1 << 20); close(fd)
        var before = stat(); lstat(disk, &before)
        let s = await detect(h, DockerWorld(), h.layout([h.definition(disk: [disk])]))
        let img = try XCTUnwrap(s[0].diskImage)
        XCTAssertEqual(img.logicalBytes, 8 << 30); XCTAssertLessThan(img.allocatedBytes, 64 << 20); XCTAssertGreaterThanOrEqual(img.allocatedBytes, 1 << 20)
        var after = stat(); lstat(disk, &after)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec); XCTAssertEqual(before.st_size, after.st_size)
    }

    func testNotInstalled() async throws {
        let h = try DockerHome(socket: false, cli: false)
        let s = await detect(h, DockerWorld())
        XCTAssertEqual(s.map(\.state), [.notInstalled])
    }
}
