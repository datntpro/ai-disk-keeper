import Foundation

/// How an item is cleaned. Encoded with a `kind` discriminator.
public enum CleanupMethod: Codable, Sendable, Hashable {
    /// Move to Trash (default).
    case trash
    /// Trash the worktree dir, then `git worktree prune` in `mainRepoPath`.
    case trashWorktree(mainRepoPath: String)
    /// Run the tool's own CLI. Executable resolution happens at cleanup time, not here.
    case toolCommand(command: String, arguments: [String])
    /// Trash an application bundle (run-state and bundle checks happen at cleanup time).
    case trashApplication(bundleID: String)
    /// Report only; never cleanable.
    case none

    public var isActionable: Bool {
        if case .none = self { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case kind, mainRepoPath, command, arguments, bundleID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "trash":
            self = .trash
        case "trashWorktree":
            self = .trashWorktree(mainRepoPath: try c.decode(String.self, forKey: .mainRepoPath))
        case "toolCommand":
            self = .toolCommand(command: try c.decode(String.self, forKey: .command),
                                arguments: try c.decode([String].self, forKey: .arguments))
        case "trashApplication":
            let bundleID = try c.decode(String.self, forKey: .bundleID)
            guard RuleCleanup.isValidBundleID(bundleID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bundleID, in: c, debugDescription: "bundleID must be a bundle id like com.example.App")
            }
            self = .trashApplication(bundleID: bundleID)
        case "none":
            self = .none
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "Unknown cleanup kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .trash:
            try c.encode("trash", forKey: .kind)
        case .trashWorktree(let path):
            try c.encode("trashWorktree", forKey: .kind)
            try c.encode(path, forKey: .mainRepoPath)
        case .toolCommand(let command, let arguments):
            try c.encode("toolCommand", forKey: .kind)
            try c.encode(command, forKey: .command)
            try c.encode(arguments, forKey: .arguments)
        case .trashApplication(let bundleID):
            try c.encode("trashApplication", forKey: .kind)
            try c.encode(bundleID, forKey: .bundleID)
        case .none:
            try c.encode("none", forKey: .kind)
        }
    }
}
