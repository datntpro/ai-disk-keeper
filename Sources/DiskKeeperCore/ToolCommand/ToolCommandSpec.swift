import Foundation

/// Whole-string, ASCII-only patterns for the variable slots of a command template. Never starts with `-`,
/// never contains NUL, space or `=`, at most 255 bytes.
public enum ArgPattern: Sendable, Hashable {
    case dockerImageID, dockerImageRef, dockerContainerID, dockerVolumeName, uppercaseUUID

    public func matches(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 255, s.utf8.allSatisfy({ $0 < 0x80 && $0 != 0 && $0 != 0x20 && $0 != 0x3D }),
              !s.hasPrefix("-") else { return false }
        switch self {
        case .dockerImageID:
            guard s.hasPrefix("sha256:") else { return false }
            return Self.isLowerHex(s.dropFirst(7), count: 64)
        case .dockerContainerID:
            return Self.isLowerHex(Substring(s), count: 64)
        case .dockerVolumeName:
            return Self.all(s, first: Self.alnum, rest: { Self.alnum($0) || $0 == 0x5F || $0 == 0x2E || $0 == 0x2D })
        case .dockerImageRef:
            guard !s.contains("@"),
                  Self.all(s, first: Self.lowerAlnum, rest: { Self.lowerAlnum($0) || "._/:-".utf8.contains($0) }) else { return false }
            let afterSlash = s.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
            return afterSlash.filter { $0 == ":" }.count <= 1
        case .uppercaseUUID:
            let p = s.split(separator: "-", omittingEmptySubsequences: false)
            guard p.count == 5, p.map(\.count) == [8, 4, 4, 4, 12] else { return false }
            return p.allSatisfy { $0.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) } }
        }
    }

    private static func lowerAlnum(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) }
    private static func alnum(_ b: UInt8) -> Bool { lowerAlnum(b) || (b >= 0x41 && b <= 0x5A) }
    private static func isLowerHex(_ s: Substring, count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    private static func all(_ s: String, first: (UInt8) -> Bool, rest: (UInt8) -> Bool) -> Bool {
        guard let f = s.utf8.first, first(f) else { return false }
        return s.utf8.dropFirst().allSatisfy(rest)
    }
}

public enum ArgToken: Sendable, Hashable {
    case literal(String)
    case param(ArgPattern)
    /// One to `max` arguments, each matching the pattern. Must be the last token.
    case params(ArgPattern, max: Int)
}

/// What a spec's items live at.
public enum ToolTarget: Sendable {
    /// A virtual item (no file): `VirtualItemPath.parse(item.path)?.namespace == namespace`.
    case virtual(namespace: String)
    /// A real path directly under `root(environment)`.
    case path(root: @Sendable (PathEnvironment) -> String)
}

/// Which absolute candidates the executable may come from. Never `PATH`.
public struct ExecutableChoice: Sendable, Hashable {
    public let candidates: [String]
    public init(candidates: [String]) { self.candidates = candidates }
}

/// What a spec's closures can use.
public struct ToolCommandContext: Sendable {
    public let environment: PathEnvironment
    public let runner: any ToolProcessRunning
    /// Plan-time only: one probe per target instead of one per item. nil at execute time (always fresh).
    public let probes: ToolProbeCache?

    public init(environment: PathEnvironment, runner: any ToolProcessRunning, probes: ToolProbeCache? = nil) {
        self.environment = environment
        self.runner = runner
        self.probes = probes
    }

    /// The fixed base every tool command runs with. Specs add their tool keys on top.
    public var baseEnvironment: [String: String] { ToolCommandRunner.baseEnvironment(home: environment.home) }
}

/// A tiny per-plan cache of probe results, keyed by an arbitrary string (for example `"docker.ps|orbstack"`).
public final class ToolProbeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: any Sendable] = [:]
    public init() {}
    public func value<T: Sendable>(_ key: String, as _: T.Type = T.self) -> T? {
        lock.lock(); defer { lock.unlock() }
        return values[key] as? T
    }
    public func store(_ key: String, _ value: some Sendable) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

/// A compiled-in, allowlisted tool command. See PLAN §7 invariant 19.
public struct ToolCommandSpec: Sendable {
    /// Every spec's `ruleIDs` live in this namespace. `RuleValidator` rejects JSON rule ids that start with it,
    /// and `ScanEngine` drops reserved-id items that come from the JSON `RuleScanner`: a JSON rule can never
    /// produce an item a spec accepts.
    public static let reservedRuleIDPrefix = "tool."

    /// Raw UTF-8 comparison: Swift `String ==` treats compatibility-equivalent text (Kelvin sign vs K) as equal.
    static func sameBytes(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
    public let id: String
    /// Must equal `CleanupMethod.toolCommand.command` ("docker", "xcrun").
    public let command: String
    /// `ScanItem.ruleID` values allowed to use this spec.
    public let ruleIDs: Set<String>
    public let target: ToolTarget
    public let template: [ArgToken]
    /// The ONLY source of truth for the argv: the item's identity, never the method's arguments on trust.
    public let bind: @Sendable (ScanItem) -> [String]?
    public let timeout: Duration
    public let executable: @Sendable (ToolCommandContext, ScanItem) -> ExecutableChoice
    /// The complete environment. nil = the target is unreachable (for example the runtime is not running).
    public let environment: @Sendable (ToolCommandContext, ScanItem) -> [String: String]?
    public let revalidate: @Sendable (ToolCommandContext, ScanItem) async -> [CleanupBlocker]
    /// Non-nil after a clean exit = failure text.
    public let verifyAfter: (@Sendable (ToolCommandContext, ScanItem, ToolCommandResult) async -> String?)?
    /// Read-only specs (scan probes) are never matched for cleanup.
    public let isDestructive: Bool

    public init(id: String, command: String, ruleIDs: Set<String>, target: ToolTarget, template: [ArgToken],
                bind: @escaping @Sendable (ScanItem) -> [String]?, timeout: Duration,
                executable: @escaping @Sendable (ToolCommandContext, ScanItem) -> ExecutableChoice,
                environment: @escaping @Sendable (ToolCommandContext, ScanItem) -> [String: String]?,
                revalidate: @escaping @Sendable (ToolCommandContext, ScanItem) async -> [CleanupBlocker] = { _, _ in [] },
                verifyAfter: (@Sendable (ToolCommandContext, ScanItem, ToolCommandResult) async -> String?)? = nil,
                isDestructive: Bool = true) {
        precondition(ruleIDs.allSatisfy { $0.hasPrefix(Self.reservedRuleIDPrefix) },
                     "tool command spec rule ids must start with \(Self.reservedRuleIDPrefix)")
        self.id = id
        self.command = command
        self.ruleIDs = ruleIDs
        self.target = target
        self.template = template
        self.bind = bind
        self.timeout = timeout
        self.executable = executable
        self.environment = environment
        self.revalidate = revalidate
        self.verifyAfter = verifyAfter
        self.isDestructive = isDestructive
    }

    /// Token-by-token match of `args` against the template.
    func accepts(_ args: [String]) -> Bool {
        var i = 0
        for (t, token) in template.enumerated() {
            switch token {
            case .literal(let s):
                guard i < args.count, args[i].utf8.elementsEqual(s.utf8) else { return false }
                i += 1
            case .param(let p):
                guard i < args.count, p.matches(args[i]) else { return false }
                i += 1
            case .params(let p, let max):
                guard t == template.count - 1 else { return false }
                let rest = args[i...]
                guard (1...max).contains(rest.count), rest.allSatisfy({ p.matches($0) }) else { return false }
                i = args.count
            }
        }
        return i == args.count
    }
}
