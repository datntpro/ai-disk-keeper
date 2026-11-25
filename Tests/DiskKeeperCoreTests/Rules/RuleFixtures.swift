import Foundation
@testable import DiskKeeperCore

/// Thread-safe recorder for the patterns a fake guard factory received.
final class PatternRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    func record(_ p: [String]) { lock.lock(); _calls.append(p); lock.unlock() }
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
}

enum RuleFixtures {
    /// Fake guard: `.pathItself` for ~/.ssh, ~/.claude.json and the extra patterns (and anything under them);
    /// `.containerOnly` for ~/.claude/projects, ~, $TMPDIR and /private/tmp.
    static func guardFactory(
        env: PathEnvironment, recorder: PatternRecorder? = nil
    ) -> RuleLoader.GuardFactory {
        let home = env.home, tmp = env.temporaryDirectory
        return { extra in
            recorder?.record(extra)
            if extra.contains(where: { $0.hasSuffix("/THROW") }) { throw NSError(domain: "fake", code: 1) }
            return { path in
                func under(_ prefix: String) -> Bool { path == prefix || path.hasPrefix(prefix + "/") }
                for p in [home + "/.ssh", home + "/.claude.json"] where under(p) {
                    return GuardDenial(scope: .pathItself, message: "protected: \(p)")
                }
                for e in extra where globMatchesPathOrBelow(e, path) {
                    return GuardDenial(scope: .pathItself, message: "protected by rule: \(e)")
                }
                for p in [home + "/.claude/projects", home, tmp, "/private/tmp"] where path == p {
                    return GuardDenial(scope: .containerOnly, message: "container only: \(p)")
                }
                return nil
            }
        }
    }

    /// Interprets `pattern` as a glob with `\` escapes (as the real guard does): `*`/`?`/`[..]` do not cross "/",
    /// a trailing `/**` also covers the base itself. True if `path` equals or is below a match.
    static func globMatchesPathOrBelow(_ pattern: String, _ path: String) -> Bool {
        var base = pattern
        if base.hasSuffix("/**") { base = String(base.dropLast(3)) }
        var regex = "^"
        var chars = Array(base)[...]
        while let c = chars.popFirst() {
            switch c {
            case "\\": if let n = chars.popFirst() { regex += NSRegularExpression.escapedPattern(for: String(n)) }
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            case "[":
                var cls = "["
                if chars.first == "!" { chars.removeFirst(); cls += "^" }
                while let n = chars.popFirst(), n != "]" { cls += n == "\\" ? "\\\\" : String(n) }
                regex += cls + "]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        regex += "(/.*)?$"
        guard let re = try? NSRegularExpression(pattern: regex) else { return false }
        return re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    static func environment(_ tmp: TemporaryDirectory, variables: [String: String] = [:]) -> PathEnvironment {
        PathEnvironment(home: tmp.path("home"), temporaryDirectory: tmp.path("T"), variables: variables)
    }

    static func loader(
        _ env: PathEnvironment, bundled: URL? = nil, user: URL? = nil, recorder: PatternRecorder? = nil
    ) -> RuleLoader {
        RuleLoader(environment: env, bundledRulesDirectory: bundled, userRulesDirectory: user,
                   guardFactory: guardFactory(env: env, recorder: recorder))
    }

    static let fileURL = URL(fileURLWithPath: "/virtual/test.json")

    /// A complete, valid one-rule file for tool `t`, with overridable pieces.
    static func file(
        tool: String = "t", protect: String? = nil, rules: [String]
    ) -> String {
        let protectPart = protect.map { #""protect": \#($0),"# } ?? ""
        return #"{"schemaVersion": 1, "tool": {"id": "\#(tool)", "name": "T"}, \#(protectPart) "rules": [\#(rules.joined(separator: ","))]}"#
    }

    static func rule(
        id: String = "t.r", category: String = "aiToolData", paths: String = #"["~/.t/cache"]"#,
        match: String = #"{"kind": "self"}"#, tier: String = "safe", extra: String = ""
    ) -> String {
        #"{"id": "\#(id)", "title": "R", "category": "\#(category)", "paths": \#(paths), "match": \#(match), "tier": "\#(tier)", "explanation": "x"\#(extra.isEmpty ? "" : ", " + extra)}"#
    }

    /// Doc examples. Each is copied verbatim into docs/rules.md (checked by RuleSchemaDocTests).
    static let docExamples: [(name: String, json: String)] = [
        ("Claude Code", #"""
        {
          "schemaVersion": 1,
          "tool": { "id": "claude-code", "name": "Claude Code", "docs": "https://docs.claude.com/en/docs/claude-code" },
          "protect": ["~/.claude/settings*.json", "~/.claude/skills/**"],
          "rules": [
            {
              "id": "claude-code.transcripts",
              "title": "Session transcripts",
              "category": "aiToolData",
              "paths": ["${CLAUDE_CONFIG_DIR:-~/.claude}/projects"],
              "match": { "kind": "children", "depth": 2, "glob": "*.jsonl", "type": "file" },
              "project": { "from": "claudeProjectDirName" },
              "tier": "review",
              "tierWhen": [
                { "if": { "newerThanDays": 7 }, "tier": "keep" },
                { "if": { "olderThanDays": 30 }, "tier": "safe" }
              ],
              "explanation": "One conversation's history. Deleting it removes it from `claude --resume`; your code is not affected.",
              "cleanup": { "method": "trash" }
            },
            {
              "id": "claude-code.todos",
              "title": "Todo lists",
              "category": "aiToolData",
              "paths": ["~/.claude/todos"],
              "match": { "kind": "self" },
              "tier": "safe",
              "explanation": "Per-session todo lists written by Claude Code. Old sessions do not use them."
            }
          ]
        }
        """#),
        ("Claude Desktop", #"""
        {
          "schemaVersion": 1,
          "tool": { "id": "claude-desktop", "name": "Claude Desktop" },
          "rules": [{
            "id": "claude-desktop.cache", "title": "Web caches", "category": "aiToolData",
            "paths": ["$APP_SUPPORT/Claude/Cache", "$APP_SUPPORT/Claude/Code Cache", "$APP_SUPPORT/Claude/GPUCache"],
            "match": { "kind": "self" }, "tier": "safe",
            "explanation": "Chromium HTTP/code/GPU caches; rebuilt automatically.",
            "cleanup": { "method": "trash", "requiresAppQuit": "com.anthropic.claudefordesktop" }
          }]
        }
        """#),
        ("Cursor", #"""
        {
          "schemaVersion": 1,
          "tool": { "id": "cursor", "name": "Cursor", "docs": "https://docs.cursor.com" },
          "protect": ["~/.cursor/mcp.json", "$APP_SUPPORT/Cursor/User/globalStorage/state.vscdb"],
          "rules": [
            { "id": "cursor.cache", "title": "Editor caches", "category": "aiToolData",
              "paths": ["$APP_SUPPORT/Cursor/Cache", "$APP_SUPPORT/Cursor/CachedData", "$APP_SUPPORT/Cursor/GPUCache"],
              "match": { "kind": "self" }, "tier": "safe",
              "explanation": "Electron caches; Cursor rebuilds them on launch.",
              "cleanup": { "method": "trash", "requiresAppQuit": "com.todesktop.230313mzl4w4u92" } },
            { "id": "cursor.workspace-storage", "title": "Workspace state", "category": "aiToolData",
              "paths": ["$APP_SUPPORT/Cursor/User/workspaceStorage"],
              "match": { "kind": "children", "type": "directory" },
              "tier": "review", "tierWhen": [{ "if": { "newerThanDays": 14 }, "tier": "keep" }],
              "explanation": "Per-workspace state (chat history, indexes) for one opened folder. Deleting it loses that workspace's chat history." }
          ]
        }
        """#),
        ("Orca", #"""
        {
          "schemaVersion": 1,
          "tool": { "id": "orca", "name": "Orca" },
          "rules": [
            { "id": "orca.logs", "title": "Orca logs", "category": "systemJunk",
              "paths": ["$APP_SUPPORT/orca/logs", "$LOGS/orca"],
              "match": { "kind": "self" }, "tier": "safe",
              "explanation": "Diagnostic logs; safe to delete, regenerated as Orca runs." }
          ]
        }
        """#),
        ("System", #"""
        {
          "schemaVersion": 1,
          "tool": { "id": "system", "name": "System" },
          "rules": [
            { "id": "system.agent-scratch", "title": "Agent scratch dirs", "category": "systemJunk",
              "paths": ["/private/tmp", "$TMPDIR"],
              "match": { "kind": "children", "glob": "claude-*", "type": "directory" },
              "tier": "review", "tierWhen": [{ "if": { "newerThanDays": 1 }, "tier": "keep" }],
              "explanation": "Temporary dirs from agent sessions. Ones touched in the last 24 h may belong to a running session." }
          ]
        }
        """#),
        ("Aider", #"""
        { "schemaVersion": 1, "tool": { "id": "aider", "name": "Aider" },
          "rules": [{ "id": "aider.tags-cache", "title": "Repo map cache", "category": "aiToolData",
            "paths": ["~/Developer", "~/code", "~/src"],
            "match": { "kind": "find", "name": ".aider.tags.cache.v*", "marker": ".git", "maxDepth": 4 },
            "project": { "from": "parentOfItem" }, "tier": "safe",
            "explanation": "Aider's repo-map cache; rebuilt on next run." }] }
        """#),
    ]
}
