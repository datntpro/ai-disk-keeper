import XCTest

@testable import DiskKeeperCore

/// Temp-dir repo builder using real git with an isolated environment (never reads the real home).
final class GitFixture {
    let tmp: TemporaryDirectory
    let gitURL: URL
    let home: String
    private var clock = 1_700_000_000

    init() throws {
        guard let g = GitInspector.locateGit() else { throw XCTSkip("git not found on this machine") }
        gitURL = g
        tmp = try TemporaryDirectory()
        home = try tmp.dir("home").path
        FileManager.default.createFile(atPath: home + "/.gitconfig", contents: Data())
    }

    var root: URL { tmp.url }

    func env() -> [String: String] {
        clock += 60
        let d = "@\(clock) +0000"
        return [
            "HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": home + "/.gitconfig",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
            "GIT_AUTHOR_DATE": d, "GIT_COMMITTER_DATE": d,
        ]
    }

    @discardableResult
    func git(_ args: [String], in dir: URL, allowFail: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = gitURL
        p.arguments = ["-c", "protocol.file.allow=always", "-c", "advice.detachedHead=false"] + args
        p.environment = env()
        p.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 && !allowFail {
            throw NSError(
                domain: "git", code: Int(p.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args) failed: \(String(decoding: e, as: UTF8.self))"])
        }
        return String(decoding: o, as: UTF8.self)
    }

    @discardableResult
    func makeRepo(_ name: String, commit: Bool = true) throws -> URL {
        let dir = try tmp.dir(name)
        try git(["init", "-q", "-b", "main"], in: dir)
        if commit { try self.commit(dir, file: "README.md", msg: "initial") }
        return dir
    }

    func makeBareRemote(_ name: String) throws -> URL {
        let dir = try tmp.dir(name)
        try git(["init", "-q", "--bare", "-b", "main"], in: dir)
        return dir
    }

    func addRemote(_ repo: URL, _ remote: URL, name: String = "origin") throws {
        try git(["remote", "add", name, remote.path], in: repo)
    }

    func push(_ repo: URL, _ branch: String, setUpstream: Bool = false) throws {
        try git(["push", "-q"] + (setUpstream ? ["-u"] : []) + ["origin", branch], in: repo)
    }

    func commit(_ repo: URL, file: String, msg: String, content: String? = nil) throws {
        let u = repo.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (content ?? "\(msg)\n\(UUID())\n").write(to: u, atomically: true, encoding: .utf8)
        try git(["add", "--", file], in: repo)
        try git(["commit", "-q", "-m", msg], in: repo)
    }

    func addWorktree(_ repo: URL, _ path: URL, branch: String) throws {
        try git(["worktree", "add", "-q", "-b", branch, path.path], in: repo)
    }

    func addDetachedWorktree(_ repo: URL, _ path: URL) throws {
        try git(["worktree", "add", "-q", "--detach", path.path], in: repo)
    }

    func write(_ repo: URL, _ file: String, _ content: String = "x\n") throws {
        try content.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Repo + bare origin, main pushed with upstream.
    func makeRepoWithOrigin(_ name: String) throws -> (repo: URL, origin: URL) {
        let origin = try makeBareRemote(name + "-origin.git")
        let repo = try makeRepo(name)
        try addRemote(repo, origin)
        try push(repo, "main", setUpstream: true)
        try git(["remote", "set-head", "origin", "main"], in: repo)
        return (repo, origin)
    }

    func inspector(
        gitExecutable: URL? = nil, tweak: (inout GitInspector.Configuration) -> Void = { _ in }
    ) -> GitInspector {
        var c = GitInspector.Configuration(homeDirectory: home, gitExecutable: gitExecutable ?? gitURL)
        tweak(&c)
        return GitInspector(configuration: c)
    }

    func script(_ name: String, _ body: String) throws -> URL {
        let u = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }
}
