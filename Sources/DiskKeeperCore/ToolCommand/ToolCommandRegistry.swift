import Foundation

public struct ToolCommandRefusal: Error, Sendable, Hashable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// The allowlist. `builtIn` is empty until a tool (Docker, simctl) adds its specs: one line each.
public struct ToolCommandRegistry: Sendable {
    public let specs: [ToolCommandSpec]
    public init(specs: [ToolCommandSpec]) { self.specs = specs }

    public static var builtIn: ToolCommandRegistry {
        ToolCommandRegistry(specs: [
            DockerToolCommands.specs(),
        ].flatMap { $0 })
    }

    public struct Match: Sendable {
        public let spec: ToolCommandSpec
        /// `spec.bind(item)`: this is what runs, never the method's own arguments.
        public let argv: [String]
    }

    /// Every failure becomes `toolCommandNotAllowed(reason)`.
    public func match(_ item: ScanItem, environment: PathEnvironment) -> Result<Match, ToolCommandRefusal> {
        guard case .toolCommand(let command, let args) = item.cleanupMethod else { return .failure(.init("not a tool command")) }
        guard item.ruleID.hasPrefix(ToolCommandSpec.reservedRuleIDPrefix) else {
            return .failure(.init("only built-in scanners may run a command"))
        }
        let candidates = specs.filter { $0.isDestructive && $0.command == command && $0.ruleIDs.contains(item.ruleID) }
        guard !candidates.isEmpty else { return .failure(.init("no allowlisted command '\(command)' for this item")) }
        guard candidates.count == 1, let spec = candidates.first else { return .failure(.init("ambiguous command")) }
        switch spec.target {
        case .virtual(let ns):
            guard VirtualItemPath.parse(item.path)?.namespace == ns else { return .failure(.init("wrong target kind")) }
        case .path(let root):
            guard !item.isVirtual, (item.path as NSString).deletingLastPathComponent == root(environment) else {
                return .failure(.init("wrong target kind"))
            }
        }
        guard spec.accepts(args) else { return .failure(.init("arguments do not match the template")) }
        guard let bound = spec.bind(item) else { return .failure(.init("cannot bind to the item")) }
        guard ToolCommandSpec.sameBytes(bound, args) else { return .failure(.init("arguments do not belong to this item")) }
        guard spec.accepts(bound) else { return .failure(.init("bound arguments do not match the template")) }
        return .success(Match(spec: spec, argv: bound))
    }
}
