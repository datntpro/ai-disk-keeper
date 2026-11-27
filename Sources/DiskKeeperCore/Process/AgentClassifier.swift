import Foundation

public enum AgentKind: String, Sendable, Hashable, CaseIterable, Codable {
    case claude, codex, gemini, aider, cursor, orca
    case node, bun, python, go, swift, cargo, git, xcodebuild, docker
    case vm, spotlight, defender, other

    /// A coding-agent CLI: the kinds a child process is attributed to.
    public var isAgentCLI: Bool {
        switch self {
        case .claude, .codex, .gemini, .aider, .cursor: true
        default: false
        }
    }
}

/// Name and path table only; command lines are never read.
public enum AgentClassifier {
    public static func classify(_ r: ProcessRecord) -> AgentKind { kind(name: r.name, path: r.executablePath) }

    public static func kind(name rawName: String, path rawPath: String?) -> AgentKind {
        let name = rawName.lowercased()
        let path = (rawPath ?? "").lowercased()
        if name.hasPrefix("mdworker") || name == "mds" || name == "mds_stores" { return .spotlight }
        if name == "wdavdaemon" || name.hasPrefix("wdavdaemon_") || name == "epsext" { return .defender }
        if name == "tart" || name.contains("com.apple.virtualization.virtualmachine")
            || path.contains("com.apple.virtualization.virtualmachine") { return .vm }
        let isApp = path.contains(".app/contents/")
        let leaf = (path as NSString).lastPathComponent
        // A native Claude Code install names the process after its version ("2.1.330"); only the path tells.
        // The npm install sets its process title to "claude" (so `name` matches) while the executable is `node`.
        if !isApp, name == "claude" || leaf == "claude" || path.contains("/claude/versions/") { return .claude }
        if !isApp, name == "codex" || name.hasPrefix("codex-") || leaf == "codex" || path.contains("/@openai/codex") { return .codex }
        if !isApp, name == "gemini" || leaf == "gemini" || path.contains("/@google/gemini-cli") { return .gemini }
        if !isApp, name == "aider" { return .aider }
        if name == "cursor-agent" { return .cursor }
        if name == "orca" || path.contains("/orca.app/") { return .orca }
        switch name {
        case "node", "nodejs": return .node
        case "bun": return .bun
        case "go": return .go
        case "cargo", "rustc": return .cargo
        case "git", "git-remote-https", "git-upload-pack": return .git
        case "xcodebuild", "xcbuild": return .xcodebuild
        case "docker", "com.docker.backend", "com.docker.virtualization": return .docker
        default: break
        }
        if name == "python" || name.hasPrefix("python3") || name.hasPrefix("python2") { return .python }
        if name == "swift" || name.hasPrefix("swift-") || name == "swiftc" { return .swift }
        if name.hasPrefix("docker-") { return .docker }
        return .other
    }

    /// The nearest agent CLI among the process itself and its ancestors (`ancestors` nearest first), so a `node`
    /// under `claude` is attributed to claude (the tool stays `node`).
    public static func agent(of r: ProcessRecord, ancestors: [ProcessRecord]) -> AgentKind? {
        for candidate in [r] + ancestors {
            let k = classify(candidate)
            if k.isAgentCLI { return k }
        }
        return nil
    }
}
