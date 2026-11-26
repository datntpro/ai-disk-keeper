import DiskKeeperCore
import Foundation

/// What a module screen shows. The testable core of the states work: views switch on this.
enum ModuleState: Equatable {
    case firstRun
    case needsFullDiskAccess(count: Int)
    case loading(Double?)
    case empty
    case filteredEmpty(query: String)
    case partialError(warnings: Int)
    case blockingError(String)
    case content
}

enum ModuleStateResolver {
    /// Precedence: blockingError > loading > firstRun > filteredEmpty > empty > partialError > content.
    static func state(hasRun: Bool, isLoading: Bool, progress: Double?, itemCount: Int, filteredCount: Int,
                      query: String, warnings: [ScanWarning], error: String?) -> ModuleState {
        if let error { return .blockingError(error) }
        if isLoading { return .loading(progress) }
        if !hasRun { return .firstRun }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, itemCount > 0, filteredCount == 0 { return .filteredEmpty(query: trimmed) }
        if itemCount == 0 { return .empty }
        let real = warnings.filter { $0.kind != .needsFullDiskAccess }
        if !real.isEmpty { return .partialError(warnings: real.count) }
        return .content
    }

    /// Number of distinct folders hidden by macOS because Full Disk Access is missing; nil when none or granted.
    static func fdaBanner(warnings: [ScanWarning], fdaGranted: Bool) -> Int? {
        guard !fdaGranted else { return nil }
        let paths = Set(warnings.filter { $0.kind == .needsFullDiskAccess }.map { $0.path ?? $0.message })
        return paths.isEmpty ? nil : paths.count
    }
}
