import Darwin
import Foundation

/// The `~/Library` locations that can hold an app's leftovers.
enum LibraryLocation: String, CaseIterable, Sendable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case preferences = "Preferences"
    case preferencesByHost = "Preferences/ByHost"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case savedState = "Saved Application State"
    case httpStorages = "HTTPStorages"
    case webKit = "WebKit"
    case logs = "Logs"
    case launchAgents = "LaunchAgents"
    case cookies = "Cookies"
}

struct LibraryEntry: Sendable, Hashable {
    let location: LibraryLocation
    let name: String
    let path: String
    let isDirectory: Bool
    let modified: Date?
    /// LaunchAgents only: plist `Label`.
    var launchLabel: String? = nil
    /// LaunchAgents only: `Program` or `ProgramArguments[0]`.
    var launchProgram: String? = nil

    var displayLocation: String { location.rawValue }
}

/// One listing per location, built once. Symlinked entries are dropped: leftovers are never links.
struct LibraryIndex: Sendable {
    var entries: [LibraryEntry]
    var warnings: [ScanWarning]

    init(entries: [LibraryEntry], warnings: [ScanWarning] = []) {
        self.entries = entries
        self.warnings = warnings
    }

    static func build(library: String) -> LibraryIndex {
        var entries: [LibraryEntry] = []
        var warnings: [ScanWarning] = []
        for location in LibraryLocation.allCases {
            if Task.isCancelled { break }
            let dir = library + "/" + location.rawValue
            switch DirectoryLister.names(at: dir) {
            case .failure(let e):
                switch e.code {
                case .ENOENT, .ENOTDIR: break
                case .EPERM:
                    warnings.append(ScanWarning(kind: .needsFullDiskAccess, path: dir,
                                                message: "Couldn't list \(location.rawValue). Full Disk Access may be needed to find leftovers there."))
                default:
                    warnings.append(ScanWarning(kind: .permissionDenied, path: dir,
                                                message: "Couldn't list \(location.rawValue) (permission denied)."))
                }
            case .success(let names):
                for name in names {
                    let path = dir + "/" + name
                    var st = stat()
                    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { continue }
                    if location == .preferences && name == "ByHost" { continue }
                    var entry = LibraryEntry(
                        location: location, name: name, path: path, isDirectory: (st.st_mode & S_IFMT) == S_IFDIR,
                        modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                                       + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9))
                    if location == .launchAgents, name.lowercased().hasSuffix(".plist") {
                        let (label, program) = readLaunchAgent(path)
                        entry.launchLabel = label
                        entry.launchProgram = program
                    }
                    entries.append(entry)
                }
            }
        }
        return LibraryIndex(entries: entries, warnings: warnings)
    }

    private static func readLaunchAgent(_ path: String) -> (String?, String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return (nil, nil) }
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [Any])?.first as? String
        return (dict["Label"] as? String, program)
    }
}
