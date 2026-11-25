import Darwin
import Foundation

/// Everything a path template needs from the machine. Tests build one by hand so nothing reads the real
/// home directory or process environment.
public struct PathEnvironment: Sendable, Hashable {
    /// Absolute, no trailing "/".
    public var home: String
    /// Absolute, no trailing "/". Kept as returned by the system (NOT `/private`-resolved).
    public var temporaryDirectory: String
    /// Process environment snapshot, used for `${NAME}` roots.
    public var variables: [String: String]

    public init(home: String, temporaryDirectory: String, variables: [String: String] = [:]) {
        self.home = PathEnvironment.trimTrailingSlashes(home)
        self.temporaryDirectory = PathEnvironment.trimTrailingSlashes(temporaryDirectory)
        self.variables = variables
    }

    /// The real environment: `getpwuid` home, `confstr(_CS_DARWIN_USER_TEMP_DIR)` temp dir, process env.
    public static func current() -> PathEnvironment {
        var home = ""
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        }
        if home.isEmpty { home = NSHomeDirectory() }

        var tmp = ""
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if n > 0 && n <= buffer.count { tmp = String(cString: buffer) }
        let env = ProcessInfo.processInfo.environment
        if tmp.isEmpty { tmp = env["TMPDIR"] ?? "" }
        if tmp.isEmpty { tmp = NSTemporaryDirectory() }
        return PathEnvironment(home: home, temporaryDirectory: tmp, variables: env)
    }

    public var applicationSupport: String { home + "/Library/Application Support" }
    public var caches: String { home + "/Library/Caches" }
    public var logs: String { home + "/Library/Logs" }
    public var containers: String { home + "/Library/Containers" }
    public var groupContainers: String { home + "/Library/Group Containers" }
    public var userRulesDirectory: URL {
        URL(fileURLWithPath: applicationSupport + "/AIDiskKeeper/Rules", isDirectory: true)
    }

    static func trimTrailingSlashes(_ s: String) -> String {
        var out = s
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

public enum PathExpansion: Sendable, Hashable {
    case path(String)
    case unavailable(reason: String)
}

public struct PathTemplateError: Error, Sendable, Hashable, CustomStringConvertible {
    public let template: String
    public let message: String
    public init(template: String, message: String) {
        self.template = template
        self.message = message
    }
    public var description: String { "\(message): \(template)" }
}

/// A validated path with a symbolic root, e.g. `~/.claude/projects`, `$APP_SUPPORT/Cursor/Cache`,
/// `${CLAUDE_CONFIG_DIR:-~/.claude}/projects`. Encoded as a single string.
public struct PathTemplate: Sendable, Hashable, Codable, CustomStringConvertible {
    public let raw: String
    private let root: Root
    private let components: [String]

    fileprivate indirect enum Root: Sendable, Hashable {
        case home, tmp, appSupport, caches, logs, containers, groupContainers
        case literal(String)
        case variable(name: String, fallback: FallbackBody?)
    }

    fileprivate struct FallbackBody: Sendable, Hashable {
        let root: Root
        let components: [String]
    }

    private static let rootError =
        "must start with ~, $HOME, $TMPDIR, $APP_SUPPORT, $CACHES, $LOGS, $CONTAINERS, $GROUP_CONTAINERS, ${VAR} or /private/tmp"

    public init(_ raw: String, allowGlobs: Bool = false) throws(PathTemplateError) {
        func fail(_ message: String) -> PathTemplateError { PathTemplateError(template: raw, message: message) }
        guard !raw.isEmpty else { throw fail("empty path template") }
        guard raw.utf8.count <= 1024 else { throw fail("path template longer than 1024 bytes") }
        guard raw.unicodeScalars.last != "/" else { throw fail("trailing '/' is not allowed") }

        let (root, rest): (Root, Scalars)
        do {
            (root, rest) = try PathTemplate.parseRoot(Scalars(Array(raw.unicodeScalars)), allowVariable: true, allowGlobs: allowGlobs)
        } catch let f as Failure {
            throw fail(f.message)
        } catch { throw fail("invalid path template") }

        let comps: [String]
        do { comps = try PathTemplate.parseComponents(rest, allowGlobs: allowGlobs) } catch let f as Failure {
            throw fail(f.message)
        } catch { throw fail("invalid path template") }

        self.raw = raw
        self.root = root
        self.components = comps
    }

    public var description: String { raw }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        do { self = try PathTemplate(s) } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalidPathTemplate:\(error.message)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    // MARK: Parsing (throws String messages, converted by the caller)

    private static let fixedRoots: [(String, Root)] = [
        ("$GROUP_CONTAINERS", .groupContainers), ("$APP_SUPPORT", .appSupport), ("$CONTAINERS", .containers),
        ("$TMPDIR", .tmp), ("$CACHES", .caches), ("$HOME", .home), ("$LOGS", .logs), ("~", .home),
        ("/private/tmp", .literal("/private/tmp")), ("/tmp", .literal("/tmp")),
    ]

    // Parsing works on Unicode scalars, never on Characters: a combining mark after "/" (or after `$`, `*`, `}`,
    // ...) would otherwise fuse with it into one Character and slip past the separator and forbidden-character
    // checks, while the filesystem still splits on the "/" byte.
    private typealias Scalars = ArraySlice<Unicode.Scalar>

    private static func text(_ s: Scalars) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s)
        return String(v)
    }

    private static func hasPrefix(_ s: Scalars, _ p: String) -> Bool { s.starts(with: p.unicodeScalars) }

    private static func parseRoot(_ s: Scalars, allowVariable: Bool, allowGlobs: Bool) throws -> (Root, Scalars) {
        if hasPrefix(s, "${") {
            guard allowVariable else { throw Failure("nested ${...} is not allowed in a fallback") }
            guard let close = s.firstIndex(of: "}") else { throw Failure("unclosed '${'") }
            let inner = s[(s.startIndex + 2)..<close]
            let after = s[(close + 1)...]
            guard after.isEmpty || after.first == "/" else { throw Failure("expected '/' after '}'") }
            let name: Scalars
            var fallback: FallbackBody?
            if let sep = (inner.startIndex..<max(inner.startIndex, inner.endIndex - 1)).first(where: {
                inner[$0] == ":" && inner[$0 + 1] == "-"
            }) {
                name = inner[inner.startIndex..<sep]
                let fb = inner[(sep + 2)...]
                guard !fb.isEmpty else { throw Failure("empty fallback in ${\(text(name)):-}") }
                let (fbRoot, fbRest) = try parseRoot(fb, allowVariable: false, allowGlobs: allowGlobs)
                fallback = FallbackBody(root: fbRoot, components: try parseComponents(fbRest, allowGlobs: allowGlobs))
            } else {
                name = inner
            }
            guard isValidVariableName(name) else {
                throw Failure("invalid variable name '\(text(name))' (expected [A-Z_][A-Z0-9_]{0,63})")
            }
            return (.variable(name: text(name), fallback: fallback), after)
        }
        for (token, root) in fixedRoots where hasPrefix(s, token) {
            let after = s.dropFirst(token.unicodeScalars.count)
            if after.isEmpty || after.first == "/" { return (root, after) }
        }
        throw Failure(rootError)
    }

    private static func isValidVariableName(_ s: Scalars) -> Bool {
        guard let first = s.first?.value, s.count <= 64 else { return false }
        func upper(_ b: UInt32) -> Bool { b >= 0x41 && b <= 0x5A }
        guard upper(first) || first == 0x5F else { return false }
        return s.allSatisfy { upper($0.value) || $0.value == 0x5F || ($0.value >= 0x30 && $0.value <= 0x39) }
    }

    /// `rest` is empty or starts with "/".
    private static func parseComponents(_ rest: Scalars, allowGlobs: Bool) throws -> [String] {
        guard !rest.isEmpty else { return [] }
        let parts = rest.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        for (i, scalars) in parts.enumerated() {
            let part = text(scalars)
            guard !scalars.isEmpty else { throw Failure("empty path component") }
            guard part.unicodeScalars.elementsEqual(".".unicodeScalars) == false,
                  part.unicodeScalars.elementsEqual("..".unicodeScalars) == false else {
                throw Failure("'.' and '..' components are not allowed")
            }
            if scalars.contains(where: { $0 == "$" || $0 == "~" || $0 == "\0" || $0 == "\\" }) {
                throw Failure("component '\(part)' contains a forbidden character ($ ~ \\ or NUL)")
            }
            if scalars.contains(where: { "*?[]".unicodeScalars.contains($0) }) {
                guard allowGlobs else { throw Failure("glob characters are not allowed in paths: '\(part)'") }
                if scalars.elementsEqual("**".unicodeScalars) {
                    guard i == parts.count - 1 else { throw Failure("'**' is only allowed as the final component") }
                } else if part.contains("**") || scalars.starts(with: "**".unicodeScalars) || hasStarStar(scalars) {
                    throw Failure("'**' must be a whole component: '\(part)'")
                } else {
                    do { _ = try RuleGlob(part) } catch { throw Failure(error.message) }
                }
            }
        }
        return parts.map(text)
    }

    private static func hasStarStar(_ s: Scalars) -> Bool {
        zip(s, s.dropFirst()).contains { $0 == "*" && $1 == "*" }
    }

    // MARK: Expansion

    public func expand(in env: PathEnvironment) -> PathExpansion {
        expand(in: env, escapeRoot: false)
    }

    /// For protect templates: the expansion as a *glob pattern*. The parts that come from the machine
    /// (home, temp dir, `${VAR}` values) are backslash-escaped (`\ * ? [ ]`) so a home like `/Users/a[1]` stays
    /// literal; the template's own components keep their globs.
    public func expandPattern(in env: PathEnvironment) -> PathExpansion {
        expand(in: env, escapeRoot: true)
    }

    /// The glob-free leading part of the expansion (root + components before the first glob component) and
    /// that first glob component, if any. `nil` if the template is unavailable. Used to judge how broad a
    /// protect pattern is.
    func literalPrefix(in env: PathEnvironment) -> (prefix: String, nextGlob: String?)? {
        guard let base = PathTemplate.expandRoot(root, env: env, escape: false) else { return nil }
        func isGlob(_ c: String) -> Bool { c.unicodeScalars.contains(where: { "*?[]".unicodeScalars.contains($0) }) }
        let literal = components.prefix { !isGlob($0) }
        let next = components.dropFirst(literal.count).first
        return (([base] + literal).joined(separator: "/"), next)
    }

    private func expand(in env: PathEnvironment, escapeRoot: Bool) -> PathExpansion {
        guard let base = PathTemplate.expandRoot(root, env: env, escape: escapeRoot) else {
            if case .variable(let name, _) = root { return .unavailable(reason: "\(name) is not set") }
            return .unavailable(reason: "cannot expand \(raw)")
        }
        return .path(([base] + components).joined(separator: "/"))
    }

    /// A `${VAR}` value is usable if it is absolute, has no `.`/`..` components and no control characters.
    /// Returned lexically cleaned (empty components dropped, no trailing "/").
    private static func cleanVariableValue(_ value: String) -> String? {
        let scalars = value.unicodeScalars
        guard scalars.first == "/", !scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let comps = scalars.split(separator: "/", omittingEmptySubsequences: true)   // scalars, not Characters
        guard !comps.isEmpty,
              !comps.contains(where: { $0.elementsEqual("..".unicodeScalars) || $0.elementsEqual(".".unicodeScalars) })
        else { return nil }
        return comps.map { String(String.UnicodeScalarView($0)) }.reduce("") { $0 + "/" + $1 }
    }

    private static func expandRoot(_ root: Root, env: PathEnvironment, escape: Bool) -> String? {
        func machine(_ s: String) -> String { escape ? ProtectedPaths.escapeGlob(s) : s }
        switch root {
        case .home: return machine(env.home)
        case .tmp: return machine(env.temporaryDirectory)
        case .appSupport: return machine(env.applicationSupport)
        case .caches: return machine(env.caches)
        case .logs: return machine(env.logs)
        case .containers: return machine(env.containers)
        case .groupContainers: return machine(env.groupContainers)
        case .literal(let s): return s
        case .variable(let name, let fallback):
            if let value = env.variables[name], let clean = cleanVariableValue(value) { return machine(clean) }
            guard let fallback, let base = expandRoot(fallback.root, env: env, escape: escape) else { return nil }
            return ([base] + fallback.components).joined(separator: "/")
        }
    }
}

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
