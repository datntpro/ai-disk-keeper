import Foundation

/// How an item is cleaned. Encoded with a `kind` discriminator.
public enum CleanupMethod: Codable, Sendable, Hashable {
    /// Move to Trash (default).
    case trash
    /// Trash the worktree dir, then `git worktree prune` in `mainRepoPath`.
    case trashWorktree(mainRepoPath: String)
    /// Run the tool's own CLI. Executable resolution happens at cleanup time, not here.
    case toolCommand(command: String, arguments: [String])
    /// Report only; never cleanable.
    case none

    public var isActionable: Bool {
        if case .none = self { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case kind, mainRepoPath, command, arguments
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
        case .none:
            try c.encode("none", forKey: .kind)
        }
    }
}
