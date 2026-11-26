import Foundation

/// What the dry run showed: the executable, the exact argv and the environment. Part of the plan entry, so an
/// edit is `planModified`, and compared again right before the command runs.
public struct ToolCommandSnapshot: Codable, Sendable, Hashable {
    public let specID: String
    public let executablePath: String
    public let argv: [String]
    public let environmentDisplay: [String: String]
    /// For example "orbstack" or a simulator runtime; nil when the target has no name.
    public let targetLabel: String?

    public init(specID: String, executablePath: String, argv: [String], environmentDisplay: [String: String],
                targetLabel: String?) {
        self.specID = specID
        self.executablePath = executablePath
        self.argv = argv
        self.environmentDisplay = environmentDisplay
        self.targetLabel = targetLabel
    }

    /// Absolute executable followed by the argv, exactly as it is spawned.
    public var command: [String] { [executablePath] + argv }
}
