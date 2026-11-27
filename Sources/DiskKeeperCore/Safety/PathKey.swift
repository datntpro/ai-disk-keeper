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

    /// Case/Unicode folding the way a case-insensitive APFS volume compares names: *full* case folding plus
    /// canonical equivalence. Verified on a real APFS volume: `Straße` and `STRASSE` are the same file (`ß` -> `ss`),
    /// as are `ﬀ`/`ff`, `ﬅ`/`ST` and `ŉ`/`ʼN`. Under-folding would let a case variant slip past a protect pattern.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }
}

protocol GlobElement: Comparable {
    init(ascii: UInt8)
}
extension Character: GlobElement { init(ascii: UInt8) { self = Character(Unicode.Scalar(ascii)) } }
extension Unicode.Scalar: GlobElement { init(ascii: UInt8) { self = Unicode.Scalar(ascii) } }

/// Component-level glob matcher. Inputs are expected to be folded already.
/// Supports `*`, `?`, `[abc]`, `[a-z]`, `[!x]` and `\` escapes. A malformed `[` is a literal.
/// `*` matches a leading dot (no FNM_PERIOD semantics).
///
/// `matches` is fail-closed: it is true if EITHER the Character (grapheme) matcher OR the Unicode-scalar
/// matcher over the NFD form matches. Characters make `?`/`[..]` match one user-perceived character;
/// scalars keep literals matching when a combining mark follows them (`id_rsa` + U+0301 vs `id_rsa*`).
enum GlobMatcher {
    static func matches(pattern: String, component: String) -> Bool {
        matchesCharacters(pattern: pattern, component: component)
            || matchesScalars(pattern: pattern, component: component)
    }

    static func matchesCharacters(pattern: String, component: String) -> Bool {
        run(Array(pattern), Array(component))
    }

    static func matchesScalars(pattern: String, component: String) -> Bool {
        run(Array(pattern.decomposedStringWithCanonicalMapping.unicodeScalars),
            Array(component.decomposedStringWithCanonicalMapping.unicodeScalars))
    }

    private enum Token<E: GlobElement> {
        case literal(E)
        case any
        case star
        case set(negated: Bool, ranges: [ClosedRange<E>])
    }

    private static func tokenize<E: GlobElement>(_ s: [E]) -> [Token<E>] {
        var out: [Token<E>] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == E(ascii: 0x2A) {
                if case .star? = out.last {} else { out.append(.star) }
                i += 1
            } else if c == E(ascii: 0x3F) {
                out.append(.any); i += 1
            } else if c == E(ascii: 0x5C) {
                if i + 1 < s.count { out.append(.literal(s[i + 1])); i += 2 } else { out.append(.literal(c)); i += 1 }
            } else if c == E(ascii: 0x5B) {
                if let (tok, next) = parseSet(s, from: i) { out.append(tok); i = next } else {
                    out.append(.literal(c)); i += 1
                }
            } else {
                out.append(.literal(c)); i += 1
            }
        }
        return out
    }

    private static func parseSet<E: GlobElement>(_ s: [E], from start: Int) -> (Token<E>, Int)? {
        var i = start + 1
        var negated = false
        if i < s.count, s[i] == E(ascii: 0x21) || s[i] == E(ascii: 0x5E) { negated = true; i += 1 }
        var ranges: [ClosedRange<E>] = []
        var first = true
        while i < s.count {
            var c = s[i]
            if c == E(ascii: 0x5D) && !first {
                return (.set(negated: negated, ranges: ranges), i + 1)
            }
            first = false
            if c == E(ascii: 0x5C), i + 1 < s.count { i += 1; c = s[i] }
            if i + 2 < s.count, s[i + 1] == E(ascii: 0x2D), s[i + 2] != E(ascii: 0x5D) {
                let hi = s[i + 2]
                if hi >= c { ranges.append(c...hi) }
                i += 3
            } else {
                ranges.append(c...c)
                i += 1
            }
        }
        return nil // unterminated
    }

    private static func run<E: GlobElement>(_ pattern: [E], _ s: [E]) -> Bool {
        let toks = tokenize(pattern)
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
                case .set(let neg, let ranges) where ranges.contains(where: { $0.contains(s[i]) }) != neg:
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
        for sc in literal.unicodeScalars {
            if "\\*?[]".unicodeScalars.contains(sc) { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(sc)
        }
        return out
    }
}
