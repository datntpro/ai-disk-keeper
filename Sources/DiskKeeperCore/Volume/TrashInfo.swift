import Darwin
import Foundation

public struct TrashInfo: Sendable, Hashable, Codable {
    public enum State: Sendable, Hashable, Codable {
        case measured
        case needsFullDiskAccess
        case unavailable(errno: Int32?)

        /// EPERM is how macOS reports a TCC-protected `~/.Trash` for an app without Full Disk Access.
        static func from(error: Error) -> State {
            if case FileSizerError.rootInaccessible(_, let code) = error {
                return code == EPERM ? .needsFullDiskAccess : .unavailable(errno: code)
            }
            if case FileSizerError.walkFailed(_, let code) = error {
                return code == EPERM ? .needsFullDiskAccess : .unavailable(errno: code)
            }
            return .unavailable(errno: nil)
        }
    }

    public let path: String
    public let state: State
    /// nil unless `state == .measured`.
    public let allocatedBytes: Int64?
    /// Top-level entries, when readable.
    public let itemCount: Int?

    public init(path: String, state: State, allocatedBytes: Int64?, itemCount: Int?) {
        self.path = path
        self.state = state
        self.allocatedBytes = allocatedBytes
        self.itemCount = itemCount
    }
}

/// Measures `~/.Trash`. Never deletes anything. Other volumes' `.Trashes` are not measured.
public struct TrashSizer: Sendable {
    private let environment: PathEnvironment
    private let size: @Sendable (URL) async throws -> SizeReport

    public init(environment: PathEnvironment, sizer: FileSizer = FileSizer()) {
        self.environment = environment
        self.size = { try await sizer.size(of: $0) }
    }

    init(environment: PathEnvironment, size: @escaping @Sendable (URL) async throws -> SizeReport) {
        self.environment = environment
        self.size = size
    }

    public func measure() async throws -> TrashInfo {
        let path = environment.home + "/.Trash"
        do {
            let report = try await size(URL(fileURLWithPath: path, isDirectory: true))
            return TrashInfo(
                path: path, state: .measured, allocatedBytes: report.allocatedBytes,
                itemCount: (try? FileManager.default.contentsOfDirectory(atPath: path))?.count)
        } catch is CancellationError {
            throw CancellationError()
        } catch FileSizerError.rootNotFound {
            return TrashInfo(path: path, state: .measured, allocatedBytes: 0, itemCount: 0)
        } catch {
            return TrashInfo(path: path, state: .from(error: error), allocatedBytes: nil, itemCount: nil)
        }
    }
}
