import Foundation

/// Identifier of a tool (open set, string-backed). Encoded as a bare string.
public struct ToolID: RawRepresentable, Codable, Sendable, Hashable, Comparable,
                      ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    /// Non-failable; does not validate (open set). Use ``isValid(_:)``.
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static func < (l: ToolID, r: ToolID) -> Bool { l.rawValue < r.rawValue }

    /// `^[a-z0-9]+(-[a-z0-9]+)*$`, max 64 characters.
    public static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= 64 else { return false }
        for part in raw.split(separator: "-", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { return false }
            for b in part.utf8 {
                let ok = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
                if !ok { return false }
            }
        }
        return true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard ToolID.isValid(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid tool id: \(raw)")
        }
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claudeCode: ToolID    = "claude-code"
    public static let claudeDesktop: ToolID = "claude-desktop"
    public static let cursor: ToolID        = "cursor"
    public static let codex: ToolID         = "codex"
    /// Gemini CLI + Antigravity.
    public static let gemini: ToolID        = "gemini"
    public static let kiro: ToolID          = "kiro"
    public static let windsurf: ToolID      = "windsurf"
    public static let copilot: ToolID       = "copilot"
    public static let aider: ToolID         = "aider"
    public static let continueDev: ToolID   = "continue"
    public static let orca: ToolID          = "orca"
    public static let ollama: ToolID        = "ollama"
    public static let huggingFace: ToolID   = "huggingface"
    public static let lmStudio: ToolID      = "lmstudio"
    public static let docker: ToolID        = "docker"
    /// Stray worktrees not attributable to a tool.
    public static let git: ToolID           = "git"
    public static let system: ToolID        = "system"

    /// All well-known constants.
    public static let wellKnown: [ToolID] = [
        .claudeCode, .claudeDesktop, .cursor, .codex, .gemini, .kiro, .windsurf,
        .copilot, .aider, .continueDev, .orca, .ollama, .huggingFace, .lmStudio,
        .docker, .git, .system,
    ]

    /// Built-in English name for well-known IDs; nil otherwise.
    public var knownDisplayName: String? {
        switch rawValue {
        case "claude-code": "Claude Code"
        case "claude-desktop": "Claude Desktop"
        case "cursor": "Cursor"
        case "codex": "Codex"
        case "gemini": "Gemini"
        case "kiro": "Kiro"
        case "windsurf": "Windsurf"
        case "copilot": "GitHub Copilot"
        case "aider": "Aider"
        case "continue": "Continue"
        case "orca": "Orca"
        case "ollama": "Ollama"
        case "huggingface": "Hugging Face"
        case "lmstudio": "LM Studio"
        case "docker": "Docker"
        case "git": "Git"
        case "system": "System"
        default: nil
        }
    }
}
