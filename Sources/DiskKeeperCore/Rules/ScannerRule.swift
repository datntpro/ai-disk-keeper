import Foundation

// Scanner rule file format, schema v1. See docs/rules.md. Decoding is strict: unknown keys are rejected at
// every level, and every field is range/syntax checked so a decoded `RuleFile` is already well-formed.
// (Cross-field and filesystem-relative checks live in `RuleValidator`.)

public struct RuleFile: Sendable, Hashable {
    public let schemaVersion: Int
    public let tool: ToolInfo
    /// Extra protect patterns (added to the global denylist, never removing from it).
    public let protect: [PathTemplate]
    public let rules: [ScannerRule]

    static let allowedKeys: Set<String> = ["schemaVersion", "tool", "protect", "rules"]
}

public struct ToolInfo: Sendable, Hashable {
    public let id: ToolID
    public let name: String
    public let docs: URL?

    static let allowedKeys: Set<String> = ["id", "name", "docs"]
}

public struct ScannerRule: Sendable, Hashable {
    public let id: String
    public let title: String
    public let category: ItemCategory
    public let paths: [PathTemplate]
    public let match: RuleMatch
    public let project: ProjectStrategy
    public let tier: RiskTier
    public let tierWhen: [TierWhen]
    public let explanation: String
    public let cleanup: RuleCleanup
    /// Optional translations of `title` / `explanation`, keyed by language tag ("vi", "zh-Hans"). English is the
    /// base fields and is never listed here.
    public let localized: [String: LocalizedRuleText]

    static let allowedKeys: Set<String> = [
        "id", "title", "category", "paths", "match", "project", "tier", "tierWhen", "explanation", "cleanup", "localized",
    ]

    /// Title and explanation for the first language in `languages` that has them: exact tag, then its language
    /// prefix (`vi-VN` → `vi`), then English. Each field falls back independently.
    public func text(for languages: [String]) -> (title: String, explanation: String) {
        var title: String?, explanation: String?
        for tag in languages {
            for candidate in Self.candidates(for: tag) {
                guard let t = localized[candidate] else { continue }
                if title == nil { title = t.title }
                if explanation == nil { explanation = t.explanation }
            }
            if title != nil, explanation != nil { break }
        }
        return (title ?? self.title, explanation ?? self.explanation)
    }

    private static func candidates(for tag: String) -> [String] {
        let t = tag.replacingOccurrences(of: "_", with: "-")
        guard let dash = t.firstIndex(of: "-") else { return [t] }
        return [t, String(t[..<dash])]
    }

    static func isValidLanguageTag(_ s: String) -> Bool {
        s.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
    }
}

public struct LocalizedRuleText: Sendable, Hashable {
    public let title: String?
    public let explanation: String?

    static let allowedKeys: Set<String> = ["title", "explanation"]
}

public enum MatchKind: String, Decodable, Sendable, Hashable, CaseIterable {
    case `self` = "self", children, find
}

public enum EntryType: String, Decodable, Sendable, Hashable, CaseIterable {
    case directory, file, any
}

public enum ProjectStrategy: String, Decodable, Sendable, Hashable, CaseIterable {
    case none, claudeProjectDirName, itemName, parentOfItem
}

public struct RuleMatch: Sendable, Hashable {
    public let kind: MatchKind
    /// `children`: entry-name glob (default `*`). nil otherwise.
    public let glob: RuleGlob?
    public let type: EntryType
    /// `children`: levels below the path (1…3, default 1).
    public let depth: Int
    public let includeHidden: Bool
    public let exclude: [RuleGlob]
    /// `find`: name of the entries to find.
    public let name: RuleGlob?
    /// `find`: sibling that must exist next to a match.
    public let marker: String?
    /// `find`: maximum search depth (1…10).
    public let maxDepth: Int?
    /// `find`: stop descending at a match (default true).
    public let prune: Bool

    static func allowedKeys(for kind: MatchKind) -> Set<String> {
        switch kind {
        case .self: ["kind"]
        case .children: ["kind", "glob", "type", "depth", "includeHidden", "exclude"]
        case .find: ["kind", "name", "marker", "type", "maxDepth", "prune", "exclude"]
        }
    }

    /// Union over all kinds (documented in the JSON schema).
    static let allKeys: Set<String> = MatchKind.allCases.reduce(into: []) { $0.formUnion(allowedKeys(for: $1)) }
}

public struct TierCondition: Sendable, Hashable {
    public let olderThanDays: Double?
    public let newerThanDays: Double?
    /// Megabytes, decimal (1 MB = 1 000 000 bytes).
    public let sizeOverMB: Double?
    public let markerExists: String?

    static let allowedKeys: Set<String> = ["olderThanDays", "newerThanDays", "sizeOverMB", "markerExists"]
}

public struct TierWhen: Sendable, Hashable {
    public let condition: TierCondition
    public let tier: RiskTier

    static let allowedKeys: Set<String> = ["if", "tier"]
}

public struct RuleCleanup: Sendable, Hashable {
    public enum Method: String, Decodable, Sendable, Hashable, CaseIterable { case trash, none, toolCommand }

    public let method: Method
    public let command: String?
    public let arguments: [String]
    /// Bundle id of an app that must be quit first. May be the literal `{name}` (see `namePlaceholder`).
    public let requiresAppQuit: String?

    /// Placeholder for `match.kind == children, depth == 1` rules: the scanner replaces it with the entry's
    /// own name (e.g. a `~/Library/Caches/<bundle-id>` folder). An entry whose name isn't a bundle id is dropped.
    public static let namePlaceholder = "{name}"

    static let allowedKeys: Set<String> = ["method", "command", "arguments", "requiresAppQuit"]

    public static let `default` = RuleCleanup(method: .trash, command: nil, arguments: [], requiresAppQuit: nil)

    public var cleanupMethod: CleanupMethod {
        switch method {
        case .trash: .trash
        case .none: .none
        case .toolCommand: .toolCommand(command: command ?? "", arguments: arguments)
        }
    }
}

// MARK: - Decoding

/// An entry name usable as a sibling/child marker: non-empty, no `/`, not `.`/`..`.
func isValidEntryName(_ s: String) -> Bool {
    let scalars = s.unicodeScalars   // scalars: "/" + combining mark is still a separator for the filesystem
    return !scalars.isEmpty && !scalars.contains("/") && !scalars.contains("\0")
        && !scalars.elementsEqual(".".unicodeScalars) && !scalars.elementsEqual("..".unicodeScalars)
}

private func invalid<K: CodingKey>(
    _ key: K, _ c: KeyedDecodingContainer<K>, _ message: String
) -> DecodingError {
    DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: message)
}

private func checkLength<K: CodingKey>(
    _ s: String, _ range: ClosedRange<Int>, _ key: K, _ c: KeyedDecodingContainer<K>, _ what: String
) throws {
    guard range.contains(s.count) else {
        throw invalid(key, c, "\(what) must be \(range.lowerBound)–\(range.upperBound) characters (got \(s.count))")
    }
}

private func checkCount<K: CodingKey, T>(
    _ a: [T], _ range: ClosedRange<Int>, _ key: K, _ c: KeyedDecodingContainer<K>, _ what: String
) throws {
    guard range.contains(a.count) else {
        throw invalid(key, c, "\(what) must have \(range.lowerBound)–\(range.upperBound) entries (got \(a.count))")
    }
}

extension RuleFile: Decodable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, tool, protect, rules }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: Self.allowedKeys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw invalid(CodingKeys.schemaVersion, c, "unsupportedSchemaVersion:\(schemaVersion) (this app reads 1)")
        }
        tool = try c.decode(ToolInfo.self, forKey: .tool)
        let protectStrings = try c.decodeIfPresent([String].self, forKey: .protect) ?? []
        var templates: [PathTemplate] = []
        for (i, raw) in protectStrings.enumerated() {
            do { templates.append(try PathTemplate(raw, allowGlobs: true)) } catch {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: c.codingPath + [CodingKeys.protect, AnyCodingKey(intValue: i)!],
                    debugDescription: "invalidPathTemplate:\(error.message)"))
            }
        }
        protect = templates
        try checkCount(protect, 0...64, CodingKeys.protect, c, "protect")
        rules = try c.decode([ScannerRule].self, forKey: .rules)
        try checkCount(rules, 1...200, CodingKeys.rules, c, "rules")
    }
}

extension ToolInfo: Decodable {
    private enum CodingKeys: String, CodingKey { case id, name, docs }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: Self.allowedKeys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ToolID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        try checkLength(name, 1...60, CodingKeys.name, c, "name")
        if let s = try c.decodeIfPresent(String.self, forKey: .docs) {
            guard s.hasPrefix("https://"), let url = URL(string: s), url.host?.isEmpty == false else {
                throw invalid(CodingKeys.docs, c, "docs must be an https:// URL")
            }
            docs = url
        } else {
            docs = nil
        }
    }
}

extension ScannerRule: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, category, paths, match, project, tier, tierWhen, explanation, cleanup, localized
    }
    private struct ProjectBody: Decodable {
        let from: ProjectStrategy
        init(from decoder: Decoder) throws {
            try decoder.rejectUnknownKeys(allowed: ["from"])
            from = try decoder.container(keyedBy: AnyCodingKey.self)
                .decode(ProjectStrategy.self, forKey: AnyCodingKey(stringValue: "from"))
        }
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: Self.allowedKeys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        try checkLength(title, 1...80, CodingKeys.title, c, "title")
        category = try c.decode(ItemCategory.self, forKey: .category)
        paths = try c.decode([PathTemplate].self, forKey: .paths)
        try checkCount(paths, 1...16, CodingKeys.paths, c, "paths")
        match = try c.decode(RuleMatch.self, forKey: .match)
        project = try c.decodeIfPresent(ProjectBody.self, forKey: .project)?.from ?? ProjectStrategy.none
        tier = try c.decode(RiskTier.self, forKey: .tier)
        tierWhen = try c.decodeIfPresent([TierWhen].self, forKey: .tierWhen) ?? []
        try checkCount(tierWhen, 0...8, CodingKeys.tierWhen, c, "tierWhen")
        explanation = try c.decode(String.self, forKey: .explanation)
        try checkLength(explanation, 1...1000, CodingKeys.explanation, c, "explanation")
        cleanup = try c.decodeIfPresent(RuleCleanup.self, forKey: .cleanup) ?? .default
        let raw = try c.decodeIfPresent([String: LocalizedRuleText].self, forKey: .localized) ?? [:]
        guard raw.count <= 16 else { throw invalid(CodingKeys.localized, c, "localized must have at most 16 languages (got \(raw.count))") }
        for tag in raw.keys {
            guard tag != "en" else {
                throw invalid(CodingKeys.localized, c, "localizedBaseLanguage: English is the base title/explanation; remove the 'en' entry")
            }
            guard Self.isValidLanguageTag(tag) else {
                throw invalid(CodingKeys.localized, c, "'\(tag)' is not a language tag such as 'vi' or 'zh-Hans'")
            }
        }
        localized = raw
    }
}

extension LocalizedRuleText: Decodable {
    private enum CodingKeys: String, CodingKey { case title, explanation }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: Self.allowedKeys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        guard title != nil || explanation != nil else {
            throw invalid(CodingKeys.title, c, "a localized entry needs a title, an explanation or both")
        }
        if let title { try checkLength(title, 1...80, CodingKeys.title, c, "title") }
        if let explanation { try checkLength(explanation, 1...1000, CodingKeys.explanation, c, "explanation") }
    }
}

extension RuleMatch: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, glob, type, depth, includeHidden, exclude, name, marker, maxDepth, prune
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(MatchKind.self, forKey: .kind)
        try decoder.rejectUnknownKeys(allowed: Self.allowedKeys(for: kind))
        self.kind = kind
        exclude = try c.decodeIfPresent([RuleGlob].self, forKey: .exclude) ?? []
        try checkCount(exclude, 0...16, CodingKeys.exclude, c, "exclude")
        switch kind {
        case .self:
            glob = nil; type = .any; depth = 1; includeHidden = false
            name = nil; marker = nil; maxDepth = nil; prune = true
        case .children:
            if let g = try c.decodeIfPresent(RuleGlob.self, forKey: .glob) {
                glob = g
            } else {
                glob = try! RuleGlob("*")   // constant, always valid
            }
            type = try c.decodeIfPresent(EntryType.self, forKey: .type) ?? .any
            depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 1
            guard (1...3).contains(depth) else { throw invalid(CodingKeys.depth, c, "depth must be 1…3") }
            includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? false
            name = nil; marker = nil; maxDepth = nil; prune = true
        case .find:
            glob = nil; depth = 1; includeHidden = false
            name = try c.decode(RuleGlob.self, forKey: .name)
            let marker = try c.decode(String.self, forKey: .marker)
            guard isValidEntryName(marker) else {
                throw invalid(CodingKeys.marker, c, "marker must be a plain file name (no '/', '.', '..')")
            }
            self.marker = marker
            type = try c.decodeIfPresent(EntryType.self, forKey: .type) ?? .directory
            let maxDepth = try c.decode(Int.self, forKey: .maxDepth)
            guard (1...10).contains(maxDepth) else { throw invalid(CodingKeys.maxDepth, c, "maxDepth must be 1…10") }
            self.maxDepth = maxDepth
            prune = try c.decodeIfPresent(Bool.self, forKey: .prune) ?? true
        }
    }
}

extension TierCondition: Decodable {
    private enum CodingKeys: String, CodingKey {
        case olderThanDays, newerThanDays, sizeOverMB, markerExists, gitState
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: Self.allowedKeys.union(["gitState"]))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.gitState) {
            throw invalid(CodingKeys.gitState, c, "gitState is only available to code scanners")
        }
        func days(_ key: CodingKeys) throws -> Double? {
            guard let v = try c.decodeIfPresent(Double.self, forKey: key) else { return nil }
            guard v.isFinite, v > 0, v <= 3650 else {
                throw invalid(key, c, "\(key.rawValue) must be > 0 and ≤ 3650")
            }
            return v
        }
        olderThanDays = try days(.olderThanDays)
        newerThanDays = try days(.newerThanDays)
        if let v = try c.decodeIfPresent(Double.self, forKey: .sizeOverMB) {
            guard v.isFinite, v > 0 else { throw invalid(.sizeOverMB, c, "sizeOverMB must be > 0") }
            sizeOverMB = v
        } else {
            sizeOverMB = nil
        }
        if let m = try c.decodeIfPresent(String.self, forKey: .markerExists) {
            guard isValidEntryName(m) else {
                throw invalid(.markerExists, c, "markerExists must be a plain file name (no '/', '.', '..')")
            }
            markerExists = m
        } else {
            markerExists = nil
        }
        guard olderThanDays != nil || newerThanDays != nil || sizeOverMB != nil || markerExists != nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "a condition needs at least one key"))
        }
    }
}

extension TierWhen: Decodable {
    private enum CodingKeys: String, CodingKey { case condition = "if", tier }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowed: Self.allowedKeys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        condition = try c.decode(TierCondition.self, forKey: .condition)
        tier = try c.decode(RiskTier.self, forKey: .tier)
    }
}

extension RuleCleanup: Decodable {
    private enum CodingKeys: String, CodingKey { case method, command, arguments, requiresAppQuit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let method = try c.decode(Method.self, forKey: .method)
        var allowed: Set<String> = ["method", "requiresAppQuit"]
        if method == .toolCommand { allowed.formUnion(["command", "arguments"]) }
        try decoder.rejectUnknownKeys(allowed: allowed)
        self.method = method
        if method == .toolCommand {
            let command = try c.decode(String.self, forKey: .command)
            guard Self.isValidCommand(command) else {
                throw invalid(CodingKeys.command, c, "command must match ^[a-z0-9][a-z0-9._-]*$ (no '/')")
            }
            self.command = command
            arguments = try c.decode([String].self, forKey: .arguments)
            try checkCount(arguments, 0...16, CodingKeys.arguments, c, "arguments")
        } else {
            command = nil
            arguments = []
        }
        if let bundle = try c.decodeIfPresent(String.self, forKey: .requiresAppQuit) {
            guard bundle == Self.namePlaceholder || Self.isValidBundleID(bundle) else {
                throw invalid(CodingKeys.requiresAppQuit, c,
                              "requiresAppQuit must be a bundle id like com.example.App, or the placeholder {name}")
            }
            requiresAppQuit = bundle
        } else {
            requiresAppQuit = nil
        }
    }

    static func isValidCommand(_ s: String) -> Bool {
        guard let first = s.utf8.first, (first >= 0x61 && first <= 0x7A) || (first >= 0x30 && first <= 0x39) else {
            return false
        }
        return s.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    static func isValidBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy {
                ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D
            }
        }
    }
}
