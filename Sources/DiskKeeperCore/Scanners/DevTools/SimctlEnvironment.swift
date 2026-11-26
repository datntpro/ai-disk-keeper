import Darwin
import Foundation

/// Where Xcode's developer directory is. `xcrun` is only ever started when this answers: on a Mac without
/// developer tools `/usr/bin/xcrun` is a shim that pops up an installer dialog, and `xcode-select -p` never does.
public struct SimctlEnvironment: Sendable {
    public let developerDir: @Sendable () -> String?
    public init(developerDir: @escaping @Sendable () -> String?) { self.developerDir = developerDir }

    public static let live = SimctlEnvironment { Self.askXcodeSelect(URL(fileURLWithPath: "/usr/bin/xcode-select")) }

    /// Runs `xcode-select -p` (no shell, minimal environment, stdin closed). nil unless it exits 0 and prints a
    /// directory that exists.
    static func askXcodeSelect(_ executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p"]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return path
    }
}
