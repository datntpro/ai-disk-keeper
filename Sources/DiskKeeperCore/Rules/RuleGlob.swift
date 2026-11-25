import Foundation

public struct RuleGlobError: Error, Sendable, Hashable, CustomStringConvertible {
    public let pattern: String
    public let message: String
    public init(pattern: String, message: String) {
        self.pattern = pattern
        self.message = message
    }
    public var description: String { "\(message) in glob '\(pattern)'" }
}

/// A glob for ONE path component: `*`, `?`, `[abc]`, `[a-z]`, `[!x]`, `\` escape. Matching is
/// case-insensitive and Unicode-normalization-insensitive. (Not `fnmatch`: that is byte-wise.)
public struct RuleGlob: Sendable, Hashable, Codable, CustomStringConvertible {
    public let pattern: String
    /// Whole-character program (grapheme clusters; `?`/`[..]` consume one visible character).
    private let characterProgram: [Element]
    /// Scalar program over the lowercased NFD form (every `?`/`[..]` consumes one Unicode scalar). nil when the
    /// pattern has no scalar-wise reading (e.g. a class range over precomposed letters); then only the
    /// whole-character matcher applies.
    private let scalarProgram: [Element]?

    fileprivate enum Element: Sendable, Hashable {
        case star
        case any
        case literal(Character)
        case set(negated: Bool, ranges: [ClosedRange<Character>])
    }

    public init(_ pattern: String) throws(RuleGlobError) {
        func fail(_ m: String) -> RuleGlobError { RuleGlobError(pattern: pattern, message: m) }
        guard !pattern.isEmpty else { throw fail("empty pattern") }
        if pattern.unicodeScalars.contains("/") { throw fail("'/' is not allowed (a glob matches one path component)") }
        if pattern.unicodeScalars.contains("\0") { throw fail("NUL is not allowed") }
        if pattern.unicodeScalars.starts(with: "**".unicodeScalars) || pattern.contains("**")
            || RuleGlob.hasStarStar(pattern) { throw fail("'**' is not allowed in a name glob") }

        self.pattern = pattern
        // The whole-character program is authoritative for syntax errors; the scalar program is best effort.
        characterProgram = try RuleGlob.compile(Array(pattern), pattern: pattern) { Array(String($0).lowercased()) }
        scalarProgram = try? RuleGlob.compile(RuleGlob.scalarUnits(pattern), pattern: pattern) { [$0] }
    }

    private static func hasStarStar(_ s: String) -> Bool {
        zip(s.unicodeScalars, s.unicodeScalars.dropFirst()).contains { $0 == "*" && $1 == "*" }
    }

    /// Lowercased, canonically decomposed scalars, each wrapped as a one-scalar Character.
    private static func scalarUnits(_ s: String) -> [Character] {
        s.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars.map(Character.init)
    }

    /// Columns are 1-based, in units of the program being compiled.
    private static func compile(
        _ original: [Character], pattern: String, fold: (Character) -> [Character]
    ) throws(RuleGlobError) -> [Element] {
        func fail(_ m: String) -> RuleGlobError { RuleGlobError(pattern: pattern, message: m) }
        func foldOne(_ c: Character) -> Character { fold(c).first ?? c }

        var out: [Element] = []
        var i = 0
        while i < original.count {
            let c = original[i]
            switch c {
            case "*": out.append(.star); i += 1
            case "?": out.append(.any); i += 1
            case "\\":
                guard i + 1 < original.count else { throw fail("trailing '\\' at position \(i + 1)") }
                out.append(contentsOf: fold(original[i + 1]).map { .literal($0) })
                i += 2
            case "[":
                let start = i
                i += 1
                var negated = false
                if i < original.count, original[i] == "!" { negated = true; i += 1 }
                var ranges: [ClosedRange<Character>] = []
                var closed = false
                while i < original.count {
                    var lo = original[i]
                    if lo == "]" { closed = true; i += 1; break }
                    if lo == "\\" {
                        guard i + 1 < original.count else { throw fail("trailing '\\' at position \(i + 1)") }
                        i += 1
                        lo = original[i]
                    }
                    i += 1
                    var hi = lo
                    if i + 1 < original.count, original[i] == "-", original[i + 1] != "]" {
                        hi = original[i + 1]
                        if hi == "\\" {
                            guard i + 2 < original.count else { throw fail("trailing '\\' at position \(i + 2)") }
                            hi = original[i + 2]
                            i += 1
                        }
                        i += 2
                    }
                    let l = foldOne(lo), h = foldOne(hi)
                    guard l <= h else {
                        throw fail("reversed range '\(lo)-\(hi)' at position \(start + 1)")
                    }
                    ranges.append(l...h)
                }
                guard closed else { throw fail("unclosed '[' at position \(start + 1)") }
                guard !ranges.isEmpty else { throw fail("empty class at position \(start + 1)") }
                out.append(.set(negated: negated, ranges: ranges))
            default:
                out.append(contentsOf: fold(c).map { .literal($0) })
                i += 1
            }
        }
        return out
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        do { self = try RuleGlob(s) } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalidGlob:\(error.message)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(pattern)
    }

    public var description: String { pattern }

    /// Case-insensitive, normalization-insensitive match of one path component. `?` and `[...]` consume one
    /// whole character (`é` is one character, precomposed or not). Ranges compare characters in Unicode order.
    ///
    /// Use this for *selecting* things. For anything that *excludes or protects*, use ``matchesEither(_:)``.
    public func matches(_ name: String) -> Bool {
        RuleGlob.run(characterProgram, Array(name.lowercased()))
    }

    /// Same pattern, but `?`/`[...]` consume one Unicode scalar of the NFD form (the pre-character behaviour).
    public func matchesScalarwise(_ name: String) -> Bool {
        scalarProgram.map { RuleGlob.run($0, RuleGlob.scalarUnits(name)) } ?? false
    }

    /// True if the whole-character OR the scalar-wise matcher matches. A name with a combining mark or ZWJ
    /// next to a literal fuses into a different character (`id_rsa` + U+0301), so one matcher alone can
    /// narrow what the other catches; exclusion/protection must block the superset of both.
    public func matchesEither(_ name: String) -> Bool { matches(name) || matchesScalarwise(name) }

    private static func run(_ elements: [Element], _ text: [Character]) -> Bool {
        var p = 0, t = 0
        var starP = -1, starT = 0
        while t < text.count {
            if p < elements.count {
                switch elements[p] {
                case .star:
                    starP = p; starT = t; p += 1; continue
                case .any:
                    p += 1; t += 1; continue
                case .literal(let s) where s == text[t]:
                    p += 1; t += 1; continue
                case .set(let negated, let ranges):
                    let hit = ranges.contains { $0.contains(text[t]) }
                    if hit != negated { p += 1; t += 1; continue }
                default: break
                }
            }
            guard starP >= 0 else { return false }
            starT += 1
            t = starT
            p = starP + 1
        }
        while p < elements.count, case .star = elements[p] { p += 1 }
        return p == elements.count
    }
}
