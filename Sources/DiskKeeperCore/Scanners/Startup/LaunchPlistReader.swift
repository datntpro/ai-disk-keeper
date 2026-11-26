import Darwin
import Foundation

/// What a launch plist says, before the scanner adds file-system and signature facts. Pure and read-only.
struct ParsedLaunchPlist: Sendable, Equatable {
    var label: String?
    var program: String?
    var arguments: [String] = []
    var schedules: [StartupItem.Schedule] = []
    var isBundleManaged = false
    var parseError: String?
}

enum LaunchPlistReader {
    /// A plist bigger than this is not a launch plist.
    static let maxBytes = 1 << 20

    static func read(path: String) -> ParsedLaunchPlist {
        guard let handle = FileHandle(forReadingAtPath: path) else { return failure("Couldn't open the file.") }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { return failure("Couldn't read the file.") }
        if data.count > maxBytes { return failure("The file is larger than 1 MiB.") }
        return parse(data)
    }

    static func parse(_ data: Data) -> ParsedLaunchPlist {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return failure("Not a valid property list.")
        }
        guard let dict = object as? [String: Any] else { return failure("The property list is not a dictionary.") }
        var parsed = ParsedLaunchPlist()
        guard let label = dict["Label"] as? String, !label.isEmpty else {
            parsed.parseError = "The property list has no Label."
            return parsed
        }
        parsed.label = label
        let args = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        parsed.arguments = args
        // BundleProgram (SMAppService) wins: the app manages the item, whatever ProgramArguments says.
        if dict["BundleProgram"] is String { parsed.isBundleManaged = true }
        if let program = dict["Program"] as? String, !program.isEmpty {
            parsed.program = program
        } else if let first = args.first, !first.isEmpty {
            parsed.program = first
        }
        if (dict["RunAtLoad"] as? Bool) == true { parsed.schedules.append(.atLoad) }
        switch dict["KeepAlive"] {
        case let flag as Bool where flag: parsed.schedules.append(.keepAlive)
        case is [String: Any]: parsed.schedules.append(.keepAlive)
        default: break
        }
        if let seconds = (dict["StartInterval"] as? NSNumber)?.intValue, seconds > 0 {
            parsed.schedules.append(.interval(seconds: seconds))
        }
        if dict["StartCalendarInterval"] is [String: Any] || dict["StartCalendarInterval"] is [Any] {
            parsed.schedules.append(.calendar)
        }
        if parsed.schedules.isEmpty { parsed.schedules = [.onDemand] }
        return parsed
    }

    private static func failure(_ message: String) -> ParsedLaunchPlist {
        var p = ParsedLaunchPlist()
        p.parseError = message
        return p
    }
}
