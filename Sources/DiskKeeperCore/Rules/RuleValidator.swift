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

        for (j, t) in file.protect.enumerated() {
            if case .path(let p) = t.expand(in: env), p == env.home || p == env.temporaryDirectory {
                return err(.invalidProtectPattern, "protect[\(j)]", "'\(t.raw)' would protect everything under it")
            }
        }

        let roots = allowedRoots(env)
        for (i, rule) in file.rules.enumerated() {
            let base = "rules[\(i)]"
            if let problem = idProblem(rule.id, tool: file.tool.id) {
                return err(.invalidRuleID, "\(base).id", problem)
            }
            if rule.category == .modelWeights {
                if rule.tier == .safe {
                    return err(.invalidValue, "\(base).tier", "model weights are always Review")
                }
                if let j = rule.tierWhen.firstIndex(where: { $0.tier == .safe }) {
                    return err(.invalidValue, "\(base).tierWhen[\(j)].tier", "model weights are always Review")
                }
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
                guard let root = roots.first(where: { norm == $0 || norm.hasPrefix($0 + "/") }) else {
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

    /// `^<tool>\.[a-z0-9]+([.-][a-z0-9]+)*$`, at most 96 characters; nil if fine.
    static func idProblem(_ id: String, tool: ToolID) -> String? {
        let prefix = tool.rawValue + "."
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

    /// `/tmp` is an alias of `/private/tmp`, `/var` of `/private/var`.
    static func aliasNormalized(_ path: String) -> String {
        for alias in ["/tmp", "/var"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }
}
