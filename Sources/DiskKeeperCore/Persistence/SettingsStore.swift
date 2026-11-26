import Darwin
import Foundation

/// Reads and writes `AppSettings` as JSON (default: Application Support/AIDiskKeeper/settings.json).
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL(environment: PathEnvironment) -> URL {
        URL(fileURLWithPath: environment.applicationSupport + "/AIDiskKeeper/settings.json")
    }

    public init(environment: PathEnvironment) { self.init(fileURL: Self.defaultFileURL(environment: environment)) }

    /// Missing file → defaults. A corrupt or newer-version file is moved aside to `settings.json.corrupt-<time>`
    /// and defaults are returned with a warning.
    public func load() -> (AppSettings, ScanWarning?) {
        guard let data = try? Data(contentsOf: fileURL) else { return (.defaults, nil) }
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            guard settings.schemaVersion <= AppSettings.currentSchemaVersion, settings.schemaVersion >= 1 else {
                throw CocoaError(.coderInvalidValue)
            }
            return (settings, nil)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent(fileURL.lastPathComponent + ".corrupt-\(stamp)")
            try? FileManager.default.removeItem(at: backup)
            let moved = (try? FileManager.default.moveItem(at: fileURL, to: backup)) != nil
            let note = moved ? "Your previous settings were unreadable and were backed up as \(backup.lastPathComponent)."
                             : "Your previous settings were unreadable."
            return (.defaults, ScanWarning(kind: .other, path: fileURL.path,
                                           message: note + " Default settings are in use."))
        }
    }

    public func save(_ settings: AppSettings) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try DiskKeeperJSON.makeEncoder(pretty: true).encode(settings)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
