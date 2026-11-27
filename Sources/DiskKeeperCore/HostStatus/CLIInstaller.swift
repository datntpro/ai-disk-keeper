import Foundation

/// "Install command-line tool…": `~/.local/bin/adk` → symlink to the `adk` inside the app. Only on an explicit click;
/// nothing else is ever created in the home folder. Remove deletes only a symlink that points at an app's `adk`.
public struct CLIInstaller: Sendable {
    public enum InstallError: Error, Equatable, Sendable {
        /// Something that is not our symlink is already there.
        case occupied(String)
        case binaryMissing(String)
    }
    public enum State: Equatable, Sendable { case notInstalled, installed, foreign }

    public let home: String
    public let binary: URL
    /// Process `PATH`, for the hint.
    public let pathVariable: String

    public init(home: String, binary: URL, pathVariable: String = ProcessInfo.processInfo.environment["PATH"] ?? "") {
        self.home = home; self.binary = binary; self.pathVariable = pathVariable
    }

    public var directory: String { home + "/.local/bin" }
    public var linkPath: String { directory + "/adk" }
    public var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }
    public var directoryInPath: Bool { pathVariable.split(separator: ":").contains { String($0) == directory } }

    private func destination() -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) }
    private var exists: Bool { (try? FileManager.default.attributesOfItem(atPath: linkPath)) != nil }
    /// Ours = a symlink to some app's `Contents/MacOS/adk` (also an old location after the app moved).
    private func isOurs(_ dest: String) -> Bool { dest == binary.path || dest.hasSuffix("/Contents/MacOS/adk") }

    public var state: State {
        guard exists else { return .notInstalled }
        if let dest = destination(), isOurs(dest) { return .installed }
        return .foreign
    }

    public func install() throws {
        guard binaryExists else { throw InstallError.binaryMissing(binary.path) }
        let fm = FileManager.default
        switch state {
        case .foreign: throw InstallError.occupied(linkPath)
        case .installed: try fm.removeItem(atPath: linkPath)
        case .notInstalled: break
        }
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: binary.path)
    }

    /// Returns false when nothing of ours was there (a foreign file is never touched).
    @discardableResult
    public func remove() throws -> Bool {
        guard state == .installed else { return false }
        try FileManager.default.removeItem(atPath: linkPath)
        return true
    }
}
