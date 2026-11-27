import Foundation

/// Semantic checks on a decoded `RuleFile` (everything the decoder can't see on its own). The protected-path
/// check needs the guard and is done by `RuleLoader` in a second phase.
public enum RuleValidator {
    /// First problem found, or nil if the file is structurally fine.
    static func validateStructure(
        _ file: RuleFile, environment env: PathEnvironment, fileURL: URL?, source: RuleSource?
    ) -> RuleLoadError? {
        func err(_ kind: RuleLoadError.Kind, _ path: String, _ message: String) -> RuleLoadError {
            RuleLoadError(kind: kind, file: fileURL, source: source, jsonPath: path, message: message)
        }

        let roots = allowedRoots(env)
        let foldedRoots = roots.map(PathCanonicalizer.fold)
        let containers = ([env.home + "/Library", env.applicationSupport, env.caches, env.logs, env.containers,
                           env.groupContainers].map { PathCanonicalizer.fold(aliasNormalized($0)) } + foldedRoots)
        // A protect pattern whose literal prefix is a root (or above one) would protect everything under it
        // (`~/**`, `~/*`, `$TMPDIR/**`, `/private/tmp`, ...) and, being a global union, disable other rules.
        for (j, t) in file.protect.enumerated() {
            guard let (prefix, nextGlob) = t.literalPrefix(in: env) else { continue }
            let norm = PathCanonicalizer.fold(aliasNormalized(prefix))   // APFS is case-insensitive: `~/library` too
            // Above a root: any glob below could cover it. At a root or a container (`~/Library`,
            // `$APP_SUPPORT`, ...): only a wildcard-ish component (`*`, `**`, `?`, `[a-z]*`, `[!.]*`, `{a,b}*`)
            // or no component at all covers everything; `keep-*` or `.[ab]x` do not.
            let wildcardish = nextGlob.map(isWildcardish) ?? true
            let above = foldedRoots.contains(where: { hasScalarPrefix($0, norm + "/") })
            let broadBase = containers.contains(norm)
            if above || (broadBase && wildcardish) {
                return err(.invalidProtectPattern, "protect[\(j)]",
                           "'\(t.raw)' is too broad: it would protect everything under \(prefix)")
            }
        }
        for (i, rule) in file.rules.enumerated() {
            let base = "rules[\(i)]"
            if let problem = idProblem(rule.id, tool: file.tool.id) {
                return err(.invalidRuleID, "\(base).id", problem)
            }
            if !rule.category.isRuleCategory {
                return err(.invalidValue, "\(base).category",
                           "category '\(rule.category.rawValue)' is produced by built-in scanners only")
            }
            if rule.category == .modelWeights {
                if rule.tier == .safe {
                    return err(.invalidValue, "\(base).tier", "model weights are always Review")
                }
                if let j = rule.tierWhen.firstIndex(where: { $0.tier == .safe }) {
                    return err(.invalidValue, "\(base).tierWhen[\(j)].tier", "model weights are always Review")
                }
            }
            if rule.cleanup.requiresAppQuit == RuleCleanup.namePlaceholder,
               !(rule.match.kind == .children && rule.match.depth == 1) {
                return err(.invalidValue, "\(base).cleanup.requiresAppQuit",
                           "{name} needs match kind children with depth 1")
            }
            for (j, when) in rule.tierWhen.enumerated() {
                let c = when.condition
                if let older = c.olderThanDays, let newer = c.newerThanDays, older >= newer {
                    return err(.invalidValue, "\(base).tierWhen[\(j)].if",
                               "olderThanDays (\(older)) must be less than newerThanDays (\(newer)); otherwise the condition can never hold")
                }
            }
            for (j, t) in rule.paths.enumerated() {
                guard case .path(let p) = t.expand(in: env) else { continue }
                let norm = aliasNormalized(p)
                guard let root = roots.first(where: { norm == $0 || hasScalarPrefix(norm, $0 + "/") }) else {
                    return err(.pathOutsideAllowedRoots, "\(base).paths[\(j)]",
                               "\(p) is outside the home directory, the temporary directory and /private/tmp")
                }
                if rule.match.kind == .self, norm == root {
                    return err(.pathOutsideAllowedRoots, "\(base).paths[\(j)]",
                               "\(p) is a root itself; a root can't be an item")
                }
            }
        }
        return nil
    }

    /// A glob component with no literal character: only `*`, `?`, `[...]` classes and `{a,b}` groups, so it can
    /// match any name (`[a-z]*`, `[!.]*`, `{a,b}*`) or a very wide set of them.
    static func isWildcardish(_ comp: String) -> Bool {
        var scalars = Array(comp.unicodeScalars)[...]
        while let c = scalars.first {
            switch c {
            case "*", "?":
                scalars = scalars.dropFirst()
            case "[", "{":
                let close: Unicode.Scalar = c == "[" ? "]" : "}"
                // `]` right after `[` / `[!` / `[^` is a member, not the end.
                var i = scalars.startIndex + 1
                if c == "[" {
                    if i < scalars.endIndex, scalars[i] == "!" || scalars[i] == "^" { i += 1 }
                    if i < scalars.endIndex, scalars[i] == "]" { i += 1 }
                }
                guard let end = scalars[i...].firstIndex(of: close) else { return false }  // literal bracket
                scalars = scalars[(end + 1)...]
            default:
                return false
            }
        }
        return true
    }

    /// `^<tool>\.[a-z0-9]+([.-][a-z0-9]+)*$`, at most 96 characters; nil if fine.
    static func idProblem(_ id: String, tool: ToolID) -> String? {
        let prefix = tool.rawValue + "."
        guard !id.hasPrefix(ToolCommandSpec.reservedRuleIDPrefix) else {
            return "rule id '\(id)' uses the reserved '\(ToolCommandSpec.reservedRuleIDPrefix)' namespace"
        }
        guard id.utf8.count <= 96 else { return "rule id is longer than 96 characters" }
        guard id.hasPrefix(prefix) else { return "rule id '\(id)' must start with '\(prefix)'" }
        let rest = id.dropFirst(prefix.count)
        let segments = rest.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "-" })
        func isAlnum(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) }
        let ok = !rest.isEmpty && segments.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy(isAlnum) }
        return ok ? nil : "rule id '\(id)' must match \(prefix)[a-z0-9]+([.-][a-z0-9]+)*"
    }

    static func allowedRoots(_ env: PathEnvironment) -> [String] {
        [env.home, env.temporaryDirectory, "/private/tmp"].map(aliasNormalized)
    }

    /// Prefix test on Unicode scalars, so "/" + combining mark can't hide a path separator.
    static func hasScalarPrefix(_ s: String, _ prefix: String) -> Bool {
        s.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// `/tmp` is an alias of `/private/tmp`, `/var` of `/private/var`.
    static func aliasNormalized(_ path: String) -> String {
        for alias in ["/tmp", "/var"] where path == alias || hasScalarPrefix(path, alias + "/") {
            return "/private" + path
        }
        return path
    }
}
