import Foundation

/// Canonical, comparison-ready form of an absolute path.
struct PathKey: Hashable, Sendable {
    let components: [String]
}

enum PathCanonicalizer {
    /// Lexical cleanup, alias map (`/System/Volumes/Data/X` -> `/X`; `/tmp|/var|/etc` -> `/private/...`),
    /// then case/Unicode folding per component.
    static func key(_ absolutePath: String) -> PathKey {
        var comps = PathNormalization.components(PathNormalization.lexical(absolutePath)).map { fold(String($0)) }
        if comps.count >= 3, comps[0] == "system", comps[1] == "volumes", comps[2] == "data" {
            comps.removeFirst(3)
        }
        if let first = comps.first, first == "tmp" || first == "var" || first == "etc" {
            comps.insert("private", at: 0)
        }
        return PathKey(components: comps)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive], locale: nil).decomposedStringWithCanonicalMapping
    }
}

/// Component-level glob matcher over Unicode scalars. Inputs are expected to be folded already.
/// Supports `*`, `?`, `[abc]`, `[a-z]`, `[!x]` and `\` escapes. A malformed `[` is a literal.
/// `*` matches a leading dot (no FNM_PERIOD semantics).
enum GlobMatcher {
    private enum Token {
        case literal(Unicode.Scalar)
        case any
        case star
        case set(negated: Bool, ranges: [ClosedRange<UInt32>])
    }

    private static func tokenize(_ pattern: String) -> [Token] {
        let s = Array(pattern.unicodeScalars)
        var out: [Token] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            switch c {
            case "*":
                if case .star? = out.last {} else { out.append(.star) }
                i += 1
            case "?":
                out.append(.any); i += 1
            case "\\":
                if i + 1 < s.count { out.append(.literal(s[i + 1])); i += 2 } else { out.append(.literal(c)); i += 1 }
            case "[":
                if let (tok, next) = parseSet(s, from: i) { out.append(tok); i = next } else {
                    out.append(.literal(c)); i += 1
                }
            default:
                out.append(.literal(c)); i += 1
            }
        }
        return out
    }

    private static func parseSet(_ s: [Unicode.Scalar], from start: Int) -> (Token, Int)? {
        var i = start + 1
        var negated = false
        if i < s.count, s[i] == "!" || s[i] == "^" { negated = true; i += 1 }
        var ranges: [ClosedRange<UInt32>] = []
        var first = true
        while i < s.count {
            var c = s[i]
            if c == "]" && !first {
                return (.set(negated: negated, ranges: ranges), i + 1)
            }
            first = false
            if c == "\\", i + 1 < s.count { i += 1; c = s[i] }
            if i + 2 < s.count, s[i + 1] == "-", s[i + 2] != "]" {
                let hi = s[i + 2]
                if hi.value >= c.value { ranges.append(c.value...hi.value) }
                i += 3
            } else {
                ranges.append(c.value...c.value)
                i += 1
            }
        }
        return nil // unterminated
    }

    static func matches(pattern: String, component: String) -> Bool {
        let toks = tokenize(pattern)
        let s = Array(component.unicodeScalars)
        var t = 0, i = 0
        var starT = -1, starI = 0
        while i < s.count {
            if t < toks.count {
                switch toks[t] {
                case .star:
                    starT = t; starI = i; t += 1
                    continue
                case .any:
                    t += 1; i += 1
                    continue
                case .literal(let l) where l == s[i]:
                    t += 1; i += 1
                    continue
                case .set(let neg, let ranges) where ranges.contains(where: { $0.contains(s[i].value) }) != neg:
                    t += 1; i += 1
                    continue
                default:
                    break
                }
            }
            if starT >= 0 {
                starI += 1; i = starI; t = starT + 1
            } else {
                return false
            }
        }
        while t < toks.count, case .star = toks[t] { t += 1 }
        return t == toks.count
    }
}

extension ProtectedPaths {
    /// Escapes glob metacharacters (`\ * ? [ ]`) so a literal path fragment can be embedded in a pattern
    /// (e.g. a home directory, `$TMPDIR` or `$HOME` expanded into `additionalPatterns`).
    public static func escapeGlob(_ literal: String) -> String {
        var out = ""
        for ch in literal {
            if "\\*?[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
