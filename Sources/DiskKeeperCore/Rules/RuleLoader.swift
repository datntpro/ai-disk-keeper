import Darwin
import Foundation

public struct UnavailablePath: Sendable, Hashable {
    public let template: String
    public let reason: String
}

public struct ResolvedRule: Sendable, Hashable {
    public let rule: ScannerRule
    public let tool: ToolID
    /// Available, validated, guard-approved absolute paths.
    public let expandedPaths: [String]
    /// Templates that couldn't be expanded here (e.g. an unset env var). Not an error.
    public let unavailablePaths: [UnavailablePath]
}

public struct RuleSet: Sendable, Hashable {
    public let source: RuleSource
    public let file: URL
    public let tool: ToolInfo
    /// This file's `protect` templates, expanded to absolute patterns.
    public let protectPatterns: [String]
    public let rules: [ResolvedRule]
}

public struct RuleLoadResult: Sendable {
    public let ruleSets: [RuleSet]
    public let errors: [RuleLoadError]

    public var allRules: [ResolvedRule] { ruleSets.flatMap(\.rules) }
    /// Union of all loaded files' protect patterns, for building the real `ProtectedPaths`.
    public var protectPatterns: [String] { ruleSets.flatMap(\.protectPatterns) }
}

/// What the injected guard says about a path.
public struct GuardDenial: Sendable, Hashable {
    public enum Scope: String, Sendable, Hashable {
        /// The path is protected, inside a protected path, outside allowed roots, or unresolvable.
        case pathItself
        /// The path itself must never be an item (an allowed root such as $TMPDIR, an exact-only dir such as
        /// ~/Developer, or an ancestor of a protected path such as ~/.claude/projects), but its contents may
        /// still be scanned. The scanner re-checks every item.
        case containerOnly
    }
    public let scope: Scope
    public let message: String
    public init(scope: Scope, message: String) {
        self.scope = scope
        self.message = message
    }
}

/// Loads, validates and resolves scanner rule files (bundled + user). Never throws: every problem becomes a
/// `RuleLoadError`; a bad file is rejected as a whole and never blocks the others. Synchronous and does
/// blocking file IO, so call it off the main actor. A value type with no shared state, hence thread-safe.
public struct RuleLoader: Sendable {
    /// Called once per load with every protect pattern from files that decoded cleanly. Returns a checker
    /// that gives a denial for a protected absolute path, or nil if allowed. May throw (bad pattern).
    public typealias GuardFactory = @Sendable (_ additionalProtectPatterns: [String]) throws
        -> @Sendable (String) -> GuardDenial?

    static let maxFileBytes = 1 << 20
    static let maxFilesPerDirectory = 200

    private let environment: PathEnvironment
    private let bundledRulesDirectory: URL?
    private let userRulesDirectory: URL?
    private let guardFactory: GuardFactory

    public init(
        environment: PathEnvironment,
        bundledRulesDirectory: URL? = CoreResources.rulesDirectoryURL,
        userRulesDirectory: URL? = nil,
        guardFactory: @escaping GuardFactory
    ) {
        self.environment = environment
        self.bundledRulesDirectory = bundledRulesDirectory
        self.userRulesDirectory = userRulesDirectory
        self.guardFactory = guardFactory
    }

    /// Decode + structural validation of one file's data (no guard). First error only.
    public func validate(data: Data, file: URL, source: RuleSource) -> Result<RuleFile, RuleLoadError> {
        guard data.count <= Self.maxFileBytes else {
            return .failure(RuleLoadError(
                kind: .fileTooLarge, file: file, source: source,
                message: "file is \(data.count) bytes; the limit is \(Self.maxFileBytes)"))
        }
        let decoded: RuleFile
        do {
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = false
            decoded = try decoder.decode(RuleFile.self, from: data)
        } catch let e as DecodingError {
            return .failure(RuleLoadError(decodingError: e, file: file, source: source))
        } catch {
            return .failure(RuleLoadError(
                kind: .invalidJSON, file: file, source: source, message: "\(error)"))
        }
        if let problem = RuleValidator.validateStructure(
            decoded, environment: environment, fileURL: file, source: source) {
            return .failure(problem)
        }
        return .success(decoded)
    }

    public func load() -> RuleLoadResult {
        var errors: [RuleLoadError] = []
        var accepted: [(file: URL, source: RuleSource, rules: RuleFile)] = []
        var seenIDs = Set<String>()

        var candidates: [(URL, RuleSource)] = []
        for (dir, source) in [(bundledRulesDirectory, RuleSource.bundled), (userRulesDirectory, .user)] {
            guard let dir else { continue }
            candidates += jsonFiles(in: dir, source: source, errors: &errors).map { ($0, source) }
        }

        for (url, source) in candidates {
            let data: Data
            switch read(url, source: source) {
            case .success(let d): data = d
            case .failure(let e): errors.append(e); continue
            }
            let file: RuleFile
            switch validate(data: data, file: url, source: source) {
            case .success(let f): file = f
            case .failure(let e): errors.append(e); continue
            }
            var local = Set<String>()
            var duplicate: RuleLoadError?
            for (i, rule) in file.rules.enumerated() where !local.insert(rule.id).inserted || seenIDs.contains(rule.id) {
                duplicate = RuleLoadError(
                    kind: .duplicateRuleID, file: url, source: source, jsonPath: "rules[\(i)].id",
                    message: "rule id '\(rule.id)' is already defined" + (source == .user ? " (bundled rules win)" : ""))
                break
            }
            if let duplicate { errors.append(duplicate); continue }
            seenIDs.formUnion(local)
            accepted.append((url, source, file))
        }

        // Expand protect patterns, then build the guard from the union. Fail closed.
        let protectPerFile = accepted.map { entry in
            entry.rules.protect.compactMap { t -> String? in
                if case .path(let p) = t.expand(in: environment) { return p }
                return nil
            }
        }
        let check: @Sendable (String) -> GuardDenial?
        do {
            check = try guardFactory(protectPerFile.flatMap { $0 })
        } catch {
            errors.append(RuleLoadError(
                kind: .guardUnavailable, file: nil, source: nil,
                message: "protected-path guard unavailable, no rules loaded: \(error)"))
            return RuleLoadResult(ruleSets: [], errors: errors)
        }

        var ruleSets: [RuleSet] = []
        for (index, entry) in accepted.enumerated() {
            var resolved: [ResolvedRule] = []
            var rejection: RuleLoadError?
            outer: for (i, rule) in entry.rules.rules.enumerated() {
                var expanded: [String] = []
                var unavailable: [UnavailablePath] = []
                for (j, template) in rule.paths.enumerated() {
                    switch template.expand(in: environment) {
                    case .unavailable(let reason):
                        unavailable.append(UnavailablePath(template: template.raw, reason: reason))
                    case .path(let path):
                        if let d = check(path), rule.match.kind == .self || d.scope == .pathItself {
                            rejection = RuleLoadError(
                                kind: .protectedPathTarget, file: entry.file, source: entry.source,
                                jsonPath: "rules[\(i)].paths[\(j)]", message: "\(path): \(d.message)")
                            break outer
                        }
                        expanded.append(path)
                    }
                }
                resolved.append(ResolvedRule(
                    rule: rule, tool: entry.rules.tool.id, expandedPaths: expanded, unavailablePaths: unavailable))
            }
            if let rejection { errors.append(rejection); continue }
            ruleSets.append(RuleSet(
                source: entry.source, file: entry.file, tool: entry.rules.tool,
                protectPatterns: protectPerFile[index], rules: resolved))
        }
        return RuleLoadResult(ruleSets: ruleSets, errors: errors)
    }

    // MARK: File access

    private func jsonFiles(in dir: URL, source: RuleSource, errors: inout [RuleLoadError]) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else { return [] }   // missing: not an error
        guard isDir.boolValue else {
            errors.append(RuleLoadError(kind: .unreadableDirectory, file: dir, source: source,
                                        message: "\(dir.path) is not a directory"))
            return []
        }
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: dir.path) } catch {
            errors.append(RuleLoadError(kind: .unreadableDirectory, file: dir, source: source,
                                        message: "cannot read \(dir.path): \(error.localizedDescription)"))
            return []
        }
        var files: [String] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = dir.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                guard source == .user, stat(path, &st) == 0 else { continue }   // follow links for user rules only
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else { continue }
            files.append(name)
        }
        if files.count > Self.maxFilesPerDirectory {
            errors.append(RuleLoadError(
                kind: .tooManyFiles, file: dir, source: source,
                message: "\(files.count) rule files in \(dir.path); loading only the first \(Self.maxFilesPerDirectory)"))
            files = Array(files.prefix(Self.maxFilesPerDirectory))
        }
        return files.map { dir.appendingPathComponent($0) }
    }

    private func read(_ url: URL, source: RuleSource) -> Result<Data, RuleLoadError> {
        var st = stat()
        if stat(url.path, &st) == 0, Int(st.st_size) > Self.maxFileBytes {
            return .failure(RuleLoadError(
                kind: .fileTooLarge, file: url, source: source,
                message: "file is \(st.st_size) bytes; the limit is \(Self.maxFileBytes)"))
        }
        do { return .success(try Data(contentsOf: url)) } catch {
            return .failure(RuleLoadError(
                kind: .unreadableFile, file: url, source: source, message: error.localizedDescription))
        }
    }
}
