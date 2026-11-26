import Darwin
import Foundation
@testable import DiskKeeperCore

/// A fake process runner: records every call, never starts a process.
final class FakeToolRunner: ToolProcessRunning, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let arguments: [String]; let environment: [String: String] }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var result = ToolCommandResult(exitStatus: 0)
    var cancel = false
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    private func record(_ c: Call) { lock.lock(); recorded.append(c); lock.unlock() }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
             maxStdout: Int) async throws -> ToolCommandResult {
        record(Call(executable: executable.path, arguments: arguments, environment: environment))
        if cancel { throw CancellationError() }
        return result
    }
}

/// A flag flipped by a spec's revalidate closure.
final class Toggle: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [CleanupBlocker] = []
    var blockers: [CleanupBlocker] { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

enum ToolFixtures {
    static let imageID = "sha256:" + String(repeating: "a", count: 64)
    static let otherID = "sha256:" + String(repeating: "b", count: 64)

    static func writeTool(in dir: TemporaryDirectory, name: String = "adk-test", body: String = "exit 0") throws -> String {
        let url = try dir.file("bin/\(name)", contents: Data("#!/bin/sh\n\(body)\n".utf8))
        chmod(url.path, 0o755)
        chmod(url.deletingLastPathComponent().path, 0o755)
        return url.path
    }

    /// `adk-test thing rm <id>` for virtual items under namespace "adktest".
    static func spec(exe: String, revalidate: Toggle = Toggle(), rules: Set<String> = ["tool.adktest.rule"],
                     target: ToolTarget = .virtual(namespace: "adktest"), extraEnv: [String: String] = ["ADK_TARGET": "t1"],
                     id: String = "adktest.thing.rm", timeout: Duration = .seconds(5)) -> ToolCommandSpec {
        ToolCommandSpec(
            id: id, command: "adk-test", ruleIDs: rules, target: target,
            template: [.literal("thing"), .literal("rm"), .param(.dockerImageID)],
            bind: { item in VirtualItemPath.parse(item.path).map { ["thing", "rm", $0.id] } },
            timeout: timeout,
            executable: { _, _ in ExecutableChoice(candidates: [exe]) },
            environment: { ctx, _ in ctx.baseEnvironment.merging(extraEnv) { $1 } },
            revalidate: { _, _ in revalidate.blockers })
    }

    static func virtualItem(id: String = imageID, rule: String = "tool.adktest.rule", method: CleanupMethod? = nil,
                            tier: RiskTier = .review, bytes: Int64 = 1000) -> ScanItem {
        let path = VirtualItemPath.build(namespace: "adktest", target: "t1", kind: "image", id: id)!
        return ScanItem(url: URL(fileURLWithPath: path), displayName: "thing", tool: "adktest", category: .aiToolData,
                        sizeAllocated: bytes, sizeLogical: bytes, fileCount: 1, lastModified: nil, tier: tier,
                        explanation: "x", ruleID: rule,
                        cleanupMethod: method ?? .toolCommand(command: "adk-test", arguments: ["thing", "rm", id]))
    }
}
