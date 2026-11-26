import Foundation

/// A table entry: the template as written plus a short reason for messages and docs.
public struct ProtectedPattern: Sendable, Hashable {
    public let template: String
    public let why: String
    public init(_ template: String, _ why: String) {
        self.template = template
        self.why = why
    }

    /// Stable identifier of the reason text ("Claude Code skills" → "claude.code.skills"). UIs key their
    /// translations on it; two entries with the same `why` share an id.
    public var id: String { Self.slug(why) }

    public static func slug(_ why: String) -> String {
        var out = "", pendingDot = false
        for ch in why.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if pendingDot, !out.isEmpty { out.append(".") }
                pendingDot = false
                out.append(ch)
            } else {
                pendingDot = true
            }
        }
        return out
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
            guard PathNormalization.isAbsolute(r), !PathNormalization.containsNUL(r), !PathNormalization.containsParentReference(r),
                  !PathNormalization.components(r).isEmpty else {
                throw ProtectedPathsError.invalidRoot(r)
            }
            return PathNormalization.lexical(r)
        }
        let home = try validRoot(homeDirectory)
        let tmp = try validRoot(temporaryDirectory)

        func forms(_ root: String) -> [String] {
            var out = [root]
            if case .resolved(let r) = resolver.resolve(root), PathNormalization.isAbsolute(r),
               PathCanonicalizer.key(r) != PathCanonicalizer.key(root) {
                out.append(PathNormalization.lexical(r))
            }
            return out
        }
        let homeForms = forms(home)
        let tmpForms = forms(tmp)
        // Fail closed on roots that would open the system (checked on lexical and resolved forms).
        let sysKeys = Self.systemRoots.map { PathCanonicalizer.key($0).components }
        func rejectBadRoot(_ original: String, _ forms: [String], isTemp: Bool) throws {
            for f in forms {
                let c = PathCanonicalizer.key(f).components
                if c.count < 2 || (c.first == "volumes" && c.count < 3)
                    || sysKeys.contains(where: { Self.isPrefix(c, of: $0) })
                    || (c.first != "volumes" || isTemp) && sysKeys.contains(where: { Self.isPrefix($0, of: c) }) {
                    throw ProtectedPathsError.invalidRoot(original)
                }
            }
        }
        try rejectBadRoot(homeDirectory, homeForms, isTemp: false)
        try rejectBadRoot(temporaryDirectory, tmpForms, isTemp: true)
        var rootKeys = (homeForms + tmpForms + ["/private/tmp"]).map(PathCanonicalizer.key)
        rootKeys = Array(Set(rootKeys))
        self.roots = rootKeys

        func expand(_ template: String) -> [String] {
            if template.hasPrefix("~") {
                return homeForms.map { Self.escapeGlob($0) + template.dropFirst() }
            }
            if template.hasPrefix("$APP_SUPPORT") {
                return homeForms.map {
                    Self.escapeGlob($0) + "/Library/Application Support" + template.dropFirst("$APP_SUPPORT".count)
                }
            }
            return [template]
        }
        func compile(_ p: ProtectedPattern) -> [Compiled] {
            expand(p.template).map {
                Compiled(template: p.template, why: p.why, components: PathCanonicalizer.key($0).components)
            }
        }

        self.anchored = Self.builtInAnchored.flatMap(compile)
            + (try additionalPatterns.map(Self.compileAdditional).map { $0 })
        self.exactOnly = Self.builtInExactOnly.flatMap { compile(ProtectedPattern($0, "protected folder")) }
        self.basenames = Self.builtInBasenames.map {
            Compiled(template: $0.template, why: $0.why, components: [PathCanonicalizer.fold($0.template)])
        }
        // Fail closed: every expanded home pattern must match the literal home path.
        for h in homeForms {
            let probe = PathCanonicalizer.key(h).components
            let pat = PathCanonicalizer.key(Self.escapeGlob(h)).components
            guard probe.count == pat.count,
                  zip(pat, probe).allSatisfy({ GlobMatcher.matches(pattern: $0, component: $1) }) else {
                throw ProtectedPathsError.invalidRoot(h)
            }
        }
        self.systemRootKeys = Self.systemRoots.map {
            Compiled(template: $0, why: "system", components: PathCanonicalizer.key($0).components)
        }
    }

    private static func compileAdditional(_ pattern: String) throws -> Compiled {
        func bad(_ why: String) -> ProtectedPathsError { .invalidPattern(pattern: pattern, reason: why) }
        guard PathNormalization.isAbsolute(pattern) else { throw bad("pattern must be absolute") }
        guard !PathNormalization.containsNUL(pattern) else { throw bad("pattern contains NUL") }
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
        guard PathNormalization.isAbsolute(path), !PathNormalization.containsNUL(path), !PathNormalization.containsParentReference(path) else {
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
        if raw.isEmpty || !PathNormalization.isAbsolute(raw) || PathNormalization.containsNUL(raw) {
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
        guard let resolved = resolvedPath, PathNormalization.isAbsolute(resolved) else {
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
        if containing.contains(where: { $0.components.count == kc.count }) {
            return Hit(reason: .protectedLocation, pattern: nil, why: "allowed root")
        }
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
        // Other credential stores
        .init("$APP_SUPPORT/Claude/claude_desktop_config.json", "Claude desktop MCP config"),
        .init("~/.cargo/credentials*", "Cargo credentials"),
        .init("~/.config/op", "1Password CLI"),
        .init("~/.vault-token", "Vault token"),
        .init("~/.terraform.d/credentials*", "Terraform credentials"),
        .init("~/.gem/credentials", "RubyGems credentials"),
        .init("~/.m2/settings*.xml", "Maven credentials"),
        .init("$APP_SUPPORT/Google/Chrome/*/Login Data*", "browser passwords"),
        .init("$APP_SUPPORT/Google/Chrome/*/Cookies*", "browser cookies"),
        .init("$APP_SUPPORT/Chromium/*/Login Data*", "browser passwords"),
        .init("$APP_SUPPORT/Chromium/*/Cookies*", "browser cookies"),
        .init("$APP_SUPPORT/BraveSoftware/Brave-Browser/*/Login Data*", "browser passwords"),
        .init("$APP_SUPPORT/BraveSoftware/Brave-Browser/*/Cookies*", "browser cookies"),
        .init("$APP_SUPPORT/Microsoft Edge/*/Login Data*", "browser passwords"),
        .init("$APP_SUPPORT/Microsoft Edge/*/Cookies*", "browser cookies"),
        .init("$APP_SUPPORT/Firefox/Profiles/*/logins.json", "browser passwords"),
        .init("$APP_SUPPORT/Firefox/Profiles/*/key4.db", "browser password key"),
        .init("$APP_SUPPORT/Firefox/Profiles/*/cookies.sqlite", "browser cookies"),
        .init("~/Library/Cookies", "browser cookies"),
        .init("/private/tmp/com.apple.launchd.*", "SSH agent socket directory"),
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
        // Media libraries are protected packages wherever the user keeps them (M4 invariant 17).
        .init("*.photoslibrary", "Photos library"),
        .init("*.photolibrary", "iPhoto library"),
        .init("*.musiclibrary", "Music library"),
        .init("*.tvlibrary", "TV library"),
        .init("*.aplibrary", "Aperture library"),
        .init("*.imovielibrary", "iMovie library"),
        .init("*.fcpbundle", "Final Cut Pro library"),
    ]

    public static let systemRoots: [String] = [
        "/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/opt", "/cores",
        "/private/etc", "/private/var/db", "/private/var/root", "/Volumes", "/Network", "/dev",
    ]
}

// MARK: Index fast path (additive; indexing/display only: cleanup and execution keep calling `check`)

extension ProtectedPaths {
    /// Longest allowed-root / system-root key. Below this depth a node's root containment equals its parent's.
    var maxRootComponents: Int {
        (systemRootKeys.map(\.components.count) + roots.map(\.components.count)).max() ?? 0
    }

    /// Anchored + exact-only patterns whose first `depth` components match a path (finite length; a trailing
    /// `**` only means "and everything below"). Empty `live` after advancing means no anchored/exact pattern
    /// can fire for this node or any descendant that is not itself protected.
    struct AnchoredCursor {
        var live: [Int]
        var depth: Int
    }

    private func pattern(_ i: Int) -> Compiled { i < anchored.count ? anchored[i] : exactOnly[i - anchored.count] }

    func anchoredCursor(forKey comps: [String]) -> AnchoredCursor {
        var c = AnchoredCursor(live: Array(0..<(anchored.count + exactOnly.count)), depth: 0)
        for comp in comps { c = advance(c, foldedComponent: comp) }
        return c
    }

    /// Keeps patterns with a component at this depth that glob-matches `foldedComponent`.
    func advance(_ c: AnchoredCursor, foldedComponent f: String) -> AnchoredCursor {
        let n = c.depth
        var out: [Int] = []
        for i in c.live {
            let p = pattern(i)
            if p.components.count > n {
                if GlobMatcher.matches(pattern: p.components[n], component: f) { out.append(i) }
            } else if i < anchored.count {
                // Fully matched anchored pattern (matches everything below). Normally the matched node was
                // itself protected, but a root evaluates as a container first, so keep it: the node never settles.
                out.append(i)
            }
        }
        return AnchoredCursor(live: out, depth: n + 1)
    }

    enum IndexKind { case none, protected, system, outside }

    /// Verdict class of one canonical key, as `evaluate` would use it (container reasons count as `.none`).
    func indexKind(forKey key: PathKey) -> IndexKind {
        guard let hit = denyReason(for: key) else { return .none }
        switch hit.reason {
        case .protectedPath, .protectedName: return .protected
        case .systemLocation: return .system
        case .outsideAllowedRoots: return .outside
        default: return .none
        }
    }

    /// True if a single path component matches a basename pattern (`protectedName`).
    func matchesBasename(_ component: String) -> Bool {
        let folded = PathCanonicalizer.fold(component)
        return basenames.contains { GlobMatcher.matches(pattern: $0.components[0], component: folded) }
    }
}
