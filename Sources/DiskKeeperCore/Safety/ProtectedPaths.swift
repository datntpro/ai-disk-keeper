import Foundation

/// A table entry: the template as written plus a short reason for messages and docs.
public struct ProtectedPattern: Sendable, Hashable {
    public let template: String
    public let why: String
    public init(_ template: String, _ why: String) {
        self.template = template
        self.why = why
    }
}

/// Immutable, non-overridable protected-path policy. See docs/protected-paths.md.
///
/// A path is denied if either its lexical form or its resolved (symlink-free) form is denied.
/// `check` never writes and never throws; scan and cleanup both call it.
public struct ProtectedPaths: Sendable {
    private struct Compiled: Sendable {
        let template: String
        let why: String
        let components: [String]
    }

    private let resolver: any PathResolving
    private let roots: [PathKey]
    private let anchored: [Compiled]
    private let exactOnly: [Compiled]
    private let basenames: [Compiled]
    private let systemRootKeys: [Compiled]

    public init(homeDirectory: String,
                temporaryDirectory: String,
                additionalPatterns: [String] = [],
                resolver: any PathResolving = SystemPathResolver()) throws {
        self.resolver = resolver
        func validRoot(_ r: String) throws -> String {
            guard r.hasPrefix("/"), !r.contains("\0"), !PathNormalization.containsParentReference(r),
                  !PathNormalization.components(r).isEmpty else {
                throw ProtectedPathsError.invalidRoot(r)
            }
            return PathNormalization.lexical(r)
        }
        let home = try validRoot(homeDirectory)
        let tmp = try validRoot(temporaryDirectory)

        func forms(_ root: String) -> [String] {
            var out = [root]
            if case .resolved(let r) = resolver.resolve(root), r.hasPrefix("/"),
               PathCanonicalizer.key(r) != PathCanonicalizer.key(root) {
                out.append(PathNormalization.lexical(r))
            }
            return out
        }
        let homeForms = forms(home)
        let tmpForms = forms(tmp)
        var rootKeys = (homeForms + tmpForms + ["/private/tmp"]).map(PathCanonicalizer.key)
        rootKeys = Array(Set(rootKeys))
        self.roots = rootKeys

        func expand(_ template: String) -> [String] {
            if template.hasPrefix("~") {
                return homeForms.map { $0 + template.dropFirst() }
            }
            if template.hasPrefix("$APP_SUPPORT") {
                return homeForms.map { $0 + "/Library/Application Support" + template.dropFirst("$APP_SUPPORT".count) }
            }
            return [template]
        }
        func compile(_ p: ProtectedPattern) -> [Compiled] {
            var seen = Set<[String]>()
            return expand(p.template).compactMap { path in
                let comps = PathCanonicalizer.key(path).components
                guard seen.insert(comps).inserted else { return nil }
                return Compiled(template: p.template, why: p.why, components: comps)
            }
        }

        self.anchored = Self.builtInAnchored.flatMap(compile)
            + (try additionalPatterns.map(Self.compileAdditional).map { $0 })
        self.exactOnly = Self.builtInExactOnly.flatMap { compile(ProtectedPattern($0, "protected folder")) }
        self.basenames = Self.builtInBasenames.map {
            Compiled(template: $0.template, why: $0.why, components: [PathCanonicalizer.fold($0.template)])
        }
        self.systemRootKeys = Self.systemRoots.map {
            Compiled(template: $0, why: "system", components: PathCanonicalizer.key($0).components)
        }
    }

    private static func compileAdditional(_ pattern: String) throws -> Compiled {
        func bad(_ why: String) -> ProtectedPathsError { .invalidPattern(pattern: pattern, reason: why) }
        guard pattern.hasPrefix("/") else { throw bad("pattern must be absolute") }
        guard !pattern.contains("\0") else { throw bad("pattern contains NUL") }
        guard !PathNormalization.containsParentReference(pattern) else { throw bad("pattern contains \"..\"") }
        var comps = PathNormalization.components(pattern).map(String.init)
        if comps.last == "**" { comps.removeLast() }
        guard !comps.isEmpty else { throw bad("pattern would match everything") }
        guard !comps.contains(where: { $0.contains("**") }) else { throw bad("\"**\" is only allowed as the final component") }
        let key = PathCanonicalizer.key("/" + comps.joined(separator: "/"))
        return Compiled(template: pattern, why: "protected by rule", components: key.components)
    }

    // MARK: Public API

    public func check(_ path: String) -> PathVerdict {
        // Cheap structural rejections first so we never resolve garbage.
        guard path.hasPrefix("/"), !path.contains("\0"), !PathNormalization.containsParentReference(path) else {
            return evaluate(raw: path, resolution: .failed(errno: EINVAL))
        }
        return evaluate(raw: path, resolution: resolver.resolve(path))
    }

    public func check(_ url: URL) -> PathVerdict {
        guard url.isFileURL else {
            return .denied(PathDenial(path: url.absoluteString, reason: .invalidPath))
        }
        return check(url.path)
    }

    // MARK: Pure core

    private struct Hit {
        let reason: PathDenial.Reason
        let pattern: String?
        let why: String?
    }

    /// Pure core: no syscalls.
    func evaluate(raw: String, resolution: PathResolution) -> PathVerdict {
        func deny(_ h: Hit, via: Bool, resolved: String?) -> PathVerdict {
            .denied(PathDenial(path: raw, reason: h.reason, matchedPattern: h.pattern, why: h.why,
                               viaSymlink: via, resolvedPath: resolved))
        }
        if raw.isEmpty || !raw.hasPrefix("/") || raw.contains("\0") {
            return .denied(PathDenial(path: raw, reason: .invalidPath))
        }
        if PathNormalization.containsParentReference(raw) {
            return .denied(PathDenial(path: raw, reason: .parentTraversal))
        }
        var resolvedPath: String?
        if case .resolved(let r) = resolution { resolvedPath = r }

        let lexical = denyReason(for: PathCanonicalizer.key(raw))
        if let l = lexical, !l.reason.isContainerReason {
            return deny(l, via: false, resolved: resolvedPath)
        }
        guard let resolved = resolvedPath, resolved.hasPrefix("/") else {
            return .denied(PathDenial(path: raw, reason: .unresolvable))
        }
        let physical = denyReason(for: PathCanonicalizer.key(resolved))
        if let p = physical, !p.reason.isContainerReason {
            return deny(p, via: true, resolved: resolved)
        }
        if let l = lexical { return deny(l, via: false, resolved: resolved) }
        if let p = physical { return deny(p, via: true, resolved: resolved) }
        return .allowed
    }

    private static func isPrefix(_ prefix: [String], of k: [String]) -> Bool {
        prefix.count <= k.count && zip(prefix, k).allSatisfy { $0 == $1 }
    }

    private func denyReason(for k: PathKey) -> Hit? {
        let kc = k.components
        // a.
        if kc.isEmpty { return Hit(reason: .systemLocation, pattern: "/", why: "filesystem root") }
        // Longest root that k equals or is under.
        let containing = roots.filter { Self.isPrefix($0.components, of: kc) }
        let under = containing.filter { $0.components.count < kc.count }
        // b.
        if containing.isEmpty,
           let sys = systemRootKeys.first(where: { Self.isPrefix($0.components, of: kc) }) {
            return Hit(reason: .systemLocation, pattern: sys.template, why: sys.why)
        }
        // c.
        var pending: Hit?
        guard let root = under.max(by: { $0.components.count < $1.components.count }) else {
            if containing.isEmpty { return Hit(reason: .outsideAllowedRoots, pattern: nil, why: nil) }
            pending = Hit(reason: .protectedLocation, pattern: nil, why: "allowed root")
            return pending
        }
        // d.
        if pending == nil, let e = exactOnly.first(where: { $0.components == kc }) {
            pending = Hit(reason: .protectedLocation, pattern: e.template, why: e.why)
        }
        // e.
        var ancestorHit: Hit?
        for p in anchored {
            let n = kc.count, m = p.components.count
            let common = min(n, m)
            guard (0..<common).allSatisfy({ GlobMatcher.matches(pattern: p.components[$0], component: kc[$0]) }) else { continue }
            if n >= m { return Hit(reason: .protectedPath, pattern: p.template, why: p.why) }
            if ancestorHit == nil { ancestorHit = Hit(reason: .containsProtectedPath, pattern: p.template, why: p.why) }
        }
        // f.
        for comp in kc.dropFirst(root.components.count) {
            for b in basenames where GlobMatcher.matches(pattern: b.components[0], component: comp) {
                return Hit(reason: .protectedName, pattern: b.template, why: b.why)
            }
        }
        // g.
        return pending ?? ancestorHit
    }

    // MARK: Built-in table (documented in docs/protected-paths.md)

    public static let builtInAnchored: [ProtectedPattern] = [
        // Claude
        .init("~/.claude.json*", "Claude Code account/config"),
        .init("~/.claude/settings*.json", "Claude Code settings"),
        .init("~/.claude/.credentials.json", "Claude Code credentials"),
        .init("~/.claude/CLAUDE.md", "Claude Code instructions"),
        .init("~/.claude/skills", "Claude Code skills"),
        .init("~/.claude/agents", "Claude Code agents"),
        .init("~/.claude/commands", "Claude Code commands"),
        .init("~/.claude/hooks", "Claude Code hooks"),
        .init("~/.claude/output-styles", "Claude Code output styles"),
        .init("~/.claude/keybindings.json", "Claude Code keybindings"),
        .init("~/.claude/plugins/config*", "Claude Code plugin config"),
        .init("~/.claude/plugins/*.json", "Claude Code plugin registry"),
        .init("~/.claude/projects/*/memory", "Claude Code auto-memory"),
        // Codex
        .init("~/.codex/auth.json", "Codex credentials"),
        .init("~/.codex/config.*", "Codex config"),
        .init("~/.codex/AGENTS.md", "Codex instructions"),
        // Gemini
        .init("~/.gemini/oauth_creds.json", "Gemini credentials"),
        .init("~/.gemini/settings.json", "Gemini settings"),
        .init("~/.gemini/google_accounts.json", "Gemini accounts"),
        .init("~/.gemini/GEMINI.md", "Gemini instructions"),
        // Cursor
        .init("~/.cursor/mcp.json", "Cursor MCP config"),
        .init("$APP_SUPPORT/Cursor/User/settings.json", "Cursor settings"),
        .init("$APP_SUPPORT/Cursor/User/keybindings.json", "Cursor keybindings"),
        .init("$APP_SUPPORT/Cursor/User/snippets", "Cursor snippets"),
        // Copilot
        .init("~/.config/github-copilot", "Copilot credentials"),
        // Dev credentials
        .init("~/.ssh", "credentials"),
        .init("~/.aws", "credentials"),
        .init("~/.gnupg", "credentials"),
        .init("~/.azure", "credentials"),
        .init("~/.kube", "credentials"),
        .init("~/.docker/config.json", "Docker credentials"),
        .init("~/.config/gh", "GitHub CLI credentials"),
        .init("~/.config/gcloud", "Google Cloud credentials"),
        .init("~/.config/git", "git config"),
        .init("~/.gitconfig", "git config"),
        .init("~/.git-credentials", "credentials"),
        .init("~/.netrc", "credentials"),
        .init("~/.npmrc", "npm credentials"),
        .init("~/.pypirc", "PyPI credentials"),
        .init("~/.password-store", "password store"),
        // macOS
        .init("~/Library/Keychains", "Keychain"),
        .init("~/Library/Preferences", "app preferences"),
        .init("~/Library/Mobile Documents", "iCloud Drive"),
        .init("~/Library/CloudStorage", "cloud storage"),
        .init("~/Library/Mail", "Mail"),
        .init("~/Library/Messages", "Messages"),
        .init("~/.Trash", "Trash"),
        // Docker
        .init("~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw", "Docker disk image"),
        // Self
        .init("$APP_SUPPORT/AIDiskKeeper", "AI Disk Keeper settings, audit log and rules"),
    ]

    public static let builtInExactOnly: [String] = [
        "~", "~/Library", "~/Library/Application Support", "~/Library/Caches", "~/Library/Logs",
        "~/Library/Containers", "~/Library/Group Containers", "~/Library/Developer", "~/Documents",
        "~/Desktop", "~/Downloads", "~/Pictures", "~/Movies", "~/Music", "~/Public", "~/Applications",
        "~/Developer", "~/.cache", "~/.config", "~/.local", "~/.local/share", "~/orca",
        "~/orca/workspaces", "/private/tmp",
        // The temporary directory itself is an allowed root and therefore a container too.
    ]

    public static let builtInBasenames: [ProtectedPattern] = [
        .init(".env", "environment secrets"),
        .init(".env.*", "environment secrets"),
        .init("*.pem", "private key"),
        .init("*.key", "private key"),
        .init("*.p12", "certificate bundle"),
        .init("*.pfx", "certificate bundle"),
        .init("*.keychain", "keychain"),
        .init("*.keychain-db", "keychain"),
        .init("id_rsa*", "SSH key"),
        .init("id_ed25519*", "SSH key"),
        .init("id_ecdsa*", "SSH key"),
        .init("id_dsa*", "SSH key"),
        .init("CLAUDE.md", "agent instructions"),
        .init("AGENTS.md", "agent instructions"),
        .init("GEMINI.md", "agent instructions"),
        .init(".credentials.json", "credentials"),
        .init(".git", "git repository data"),
    ]

    public static let systemRoots: [String] = [
        "/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/opt", "/cores",
        "/private/etc", "/private/var/db", "/private/var/root", "/Volumes", "/Network", "/dev",
    ]
}
