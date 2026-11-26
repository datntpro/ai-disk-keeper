import Darwin
import Foundation
@testable import DiskKeeperCore

/// Synthetic docker output shaped like `docker … --format '{{json .}}'` (no real runtime was available to record).
/// A scripted runner answers by argv and records every call: nothing here starts a process.
final class DockerWorld: ToolProcessRunning, @unchecked Sendable {
    static let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
    static let c = String(repeating: "c", count: 64), d = String(repeating: "d", count: 64)
    static let stopped = String(repeating: "e", count: 64), running = String(repeating: "f", count: 64)
    static let anon = String(repeating: "1", count: 64)

    private let lock = NSLock()
    private var log: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return log }
    var destructive: [[String]] { calls.filter { ["rm", "prune"].contains($0.count > 1 ? $0[1] : "") || $0.first == "builder" } }

    // Mutable world state
    var up = true
    var hangOn: String?          // first argv word to time out on
    var failRm: String?          // stderr for failing destructive commands
    var removed: Set<String> = []
    var extraContainerForImage: String?   // appears in `ancestor=` listing (race)
    var versionStatus: Int32 = 0
    var dfOverride: String?

    func run(executable: URL, arguments a: [String], environment: [String: String], timeout: Duration,
             maxStdout: Int) async throws -> ToolCommandResult {
        lock.lock(); log.append(a); lock.unlock()
        func ok(_ s: String) -> ToolCommandResult { ToolCommandResult(exitStatus: 0, stdout: Data(s.utf8)) }
        func fail(_ s: String = "boom") -> ToolCommandResult { ToolCommandResult(exitStatus: 1, stderrTail: s) }
        if let h = hangOn, a.first == h || a.prefix(2).joined(separator: " ") == h {
            return ToolCommandResult(exitStatus: -1, timedOut: true)
        }
        if a.first == "version" { return up ? ToolCommandResult(exitStatus: versionStatus, stdout: Data(#"{"Client":{"Version":"27"},"Server":{"Version":"27.0.1"}}"#.utf8)) : fail("Cannot connect") }
        guard up else { return fail("Cannot connect") }
        switch a.prefix(2).joined(separator: " ") {
        case "system df": return ok(dfOverride ?? df)
        case "image ls": return ok(imageLs)
        case "container ls":
            if let f = a.firstIndex(of: "--filter") {
                let v = a[f + 1]
                if v.hasPrefix("ancestor="), let e = extraContainerForImage, v == "ancestor=" + e { return ok(Self.running + "\n") }
                if v.hasPrefix("ancestor=sha256:" + Self.c) { return ok(Self.stopped + "\n") }
                if v == "volume=inuse" { return ok(Self.running + "\n") }
                return ok("")
            }
            return ok(containerLs)
        case "volume ls": return ok(volumeLs)
        case "image inspect":
            let id = a.last!
            if removed.contains(id) { return fail("No such image") }
            switch id {
            case "sha256:" + Self.a, "sha256:" + Self.d: return ok("\(id)|null\n")
            case "sha256:" + Self.b: return ok("\(id)|[\"app:1\",\"app:latest\"]\n")
            case "sha256:" + Self.c: return ok("\(id)|[\"web:1\"]\n")
            default: return fail("No such image")
            }
        case "container inspect":
            if removed.contains(a.last!) { return fail("No such container") }
            return ok((a.last == Self.running ? "running" : "exited") + "\n")
        case "volume inspect": return removed.contains(a.last!) ? fail("No such volume") : ok(a.last! + "\n")
        case "image rm", "container rm", "volume rm", "builder prune":
            if let f = failRm { return fail(f) }
            removed.formUnion(a.dropFirst(2)); return ok("ok\n")
        default: return fail("unexpected")
        }
    }

    let df = """
    {"Images":[
     {"ID":"aaaaaaaaaaaa","Repository":"<none>","Tag":"<none>","Containers":"0","UniqueSize":"10MB","Size":"20MB","SharedSize":"10MB"},
     {"ID":"bbbbbbbbbbbb","Repository":"app","Tag":"1","Containers":"0","UniqueSize":"1.5GB","Size":"1.5GB"},
     {"ID":"bbbbbbbbbbbb","Repository":"app","Tag":"latest","Containers":"0","UniqueSize":"1.5GB","Size":"1.5GB"},
     {"ID":"cccccccccccc","Repository":"web","Tag":"1","Containers":"1","UniqueSize":"5MB","Size":"5MB"},
     {"ID":"dddddddddddd","Repository":"<none>","Tag":"<none>","Containers":"0","UniqueSize":"3MB","Size":"3MB","Extra":"ignored"}],
     "Containers":[{"ID":"eeeeeeeeeeee","Size":"2B (virtual 72.8MB)"},{"ID":"ffffffffffff","Size":"0B"}],
     "Volumes":[{"Name":"\(DockerWorld.anon)","Links":"0","Size":"4MB"},{"Name":"pgdata","Links":"0","Size":"900MB"},{"Name":"inuse","Links":"1","Size":"1MB"}],
     "BuildCache":[{"ID":"x1","InUse":"false","Size":"1MB","LastUsedAt":"2026-11-20 10:00:00 +0000 UTC"},{"ID":"x2","InUse":"false","Size":"2MB"},{"ID":"x3","InUse":"true","Size":"50MB"}]}
    """

    var imageLs: String {
        [("a", "<none>", "<none>", "2026-11-25 10:00:00 +0000 UTC"), ("b", "app", "1", "2026-11-01 10:00:00 +0000 UTC"),
         ("b", "app", "latest", "2026-11-01 10:00:00 +0000 UTC"), ("c", "web", "1", "2026-11-01 10:00:00 +0000 UTC"),
         ("d", "<none>", "<none>", "2026-11-27 11:50:00 +0000 UTC")]
            .map { #"{"ID":"sha256:\#(String(repeating: $0.0, count: 64))","Repository":"\#($0.1)","Tag":"\#($0.2)","CreatedAt":"\#($0.3)"}"# }
            .joined(separator: "\n")
    }
    var containerLs: String {
        """
        {"ID":"\(Self.stopped)","Names":"old-web","Image":"web:1","State":"exited","Status":"Exited (0) 2 days ago","CreatedAt":"2026-11-25 10:00:00 +0000 UTC"}
        {"ID":"\(Self.running)","Names":"live","Image":"app:latest","State":"running","Status":"Up 2 hours","CreatedAt":"2026-11-27 10:00:00 +0000 UTC"}
        """
    }
    var volumeLs: String {
        """
        {"Name":"\(Self.anon)","Labels":""}
        {"Name":"pgdata","Labels":"a=b"}
        {"Name":"inuse","Labels":""}
        """
    }
}

/// A short temp dir (sun_path is ≤ 104 bytes) holding a fake home, a safe fake `docker` file and a real unix socket.
final class DockerHome {
    let root: String
    var home: String { root + "/h" }
    var cli: String { home + "/bin/docker" }
    var socket: String { home + "/.docker/run/docker.sock" }
    private var fds: [Int32] = []

    init(socket withSocket: Bool = true, cli withCLI: Bool = true) throws {
        var tmpl = Array("/private/tmp/adkd-XXXXXX".utf8CString)
        guard mkdtemp(&tmpl) != nil else { throw POSIXError(.EIO) }
        root = String(cString: tmpl)
        try FileManager.default.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.docker/run", withIntermediateDirectories: true)
        for d in [home, home + "/bin"] { chmod(d, 0o755) }
        if withCLI {
            FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            chmod(cli, 0o755)
        }
        if withSocket { fds.append(try Self.bindSocket(socket)) }
    }

    static func bindSocket(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { p in path.withCString { strlcpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, p.count) } }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    deinit { fds.forEach { close($0) }; try? FileManager.default.removeItem(atPath: root) }

    var env: PathEnvironment { PathEnvironment(home: home, temporaryDirectory: root + "/tmp", variables: [:]) }

    func definition(id: String = "docker-desktop", name: String = "Docker Desktop", socket: String? = nil,
                    disk: [String] = []) -> DockerRuntimeDefinition {
        DockerRuntimeDefinition(id: id, displayName: name, cliCandidates: [cli], socketPath: socket ?? self.socket, diskImagePaths: disk)
    }
    func layout(_ defs: [DockerRuntimeDefinition]? = nil) -> DockerRuntimeLayout {
        let d = defs ?? [definition()]
        return DockerRuntimeLayout(home: home) { d }
    }
}
