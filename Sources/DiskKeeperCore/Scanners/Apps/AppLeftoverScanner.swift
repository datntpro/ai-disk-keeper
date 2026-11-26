import Darwin
import Foundation

/// Finds files an installed app left in `~/Library` (exact bundle-id matches, conservative name matches,
/// shared items) and leftovers of apps that are no longer installed anywhere (orphans). Read-only.
/// Emits only paths under `~/Library`, which the scan guard allows, so Care Scan can run it.
public struct AppLeftoverScanner: Scanner {
    public let id = "app-leftovers"
    private let inventory: @Sendable () async throws -> AppInventory
    private let library: String
    private let lookup: any BundleLookup

    public init(inventory: @escaping @Sendable () async throws -> AppInventory, library: String,
                lookup: any BundleLookup) {
        self.inventory = inventory
        self.library = library
        self.lookup = lookup
    }

    public func scan(context: ScanContext, sink: ScanSink) async throws {
        try Task.checkCancellation()
        let apps = try await inventory().apps
        try Task.checkCancellation()
        let index = LibraryIndex.build(library: library)
        for w in index.warnings { await sink.warning(w) }
        try Task.checkCancellation()
        let lookup = self.lookup
        let matches = LeftoverResolver.resolve(apps: apps, index: index, now: context.now) {
            lookup.isInstalledAnywhere(bundleID: $0)
        }

        var progress = ScannerProgress()
        progress.candidatesFound = matches.count
        await sink.progress(progress)

        for m in matches {
            try Task.checkCancellation()
            if context.pathGuard.check(m.entry.path).denial != nil { progress.guardDropped += 1; await sink.progress(progress); continue }
            var st = stat()
            if lstat(m.entry.path, &st) == 0, st.st_uid != context.userID { progress.ownerDropped += 1; await sink.progress(progress); continue }

            var flags: Set<ItemFlag> = []
            let report: SizeReport
            do {
                report = try await context.size(URL(fileURLWithPath: m.entry.path))
            } catch is CancellationError {
                throw CancellationError()
            } catch FileSizerError.rootNotFound {
                continue
            } catch FileSizerError.rootInaccessible(let path, let code) {
                await sink.warning(ScanWarning(kind: code == EPERM ? .needsFullDiskAccess : .permissionDenied, path: path,
                                               ruleID: m.ruleID, message: "Couldn't measure this item. Full Disk Access may be needed.",
                                               code: .cannotSize(errno: code)))
                continue
            } catch {
                await sink.warning(ScanWarning(kind: .scannerFailed, path: m.entry.path, ruleID: m.ruleID,
                                               message: "Couldn't measure this item.", code: .cannotSize(errno: nil)))
                continue
            }
            if report.issueCount > 0 { flags.insert(.sizeIncomplete) }
            if report.issues.contains(where: { $0.kind == .notPermitted }) { flags.insert(.needsFullDiskAccess) }
            // A directory touched recently is probably in use, whatever its own mtime says.
            if m.level == .orphan, let newest = report.newestModification,
               context.now.timeIntervalSince(newest) <= LeftoverResolver.orphanMinAgeDays * 86_400 { continue }

            let item = Self.makeItem(m, report: report, flags: flags)
            progress.candidatesSized += 1
            progress.bytesFound += item.sizeAllocated
            await sink.item(item)
            await sink.progress(progress)
        }
    }

    static func makeItem(_ m: LeftoverMatch, report: SizeReport, flags: Set<ItemFlag>) -> ScanItem {
        let place = "\(m.entry.displayLocation)/\(m.entry.name)"
        let prefix: String
        let explanation: String
        switch m.level {
        case .exact:
            let owner = m.owner!
            prefix = owner.name
            explanation = "Settings, caches or data \(owner.name) keeps in this location. It matches the app's identifier exactly."
        case .name:
            if let owner = m.owner {
                prefix = owner.name
                explanation = "Named after \(owner.name), but not tied to it by identifier. It may be shared with other apps from the same developer; review before removing."
            } else {
                let names = Self.joined(m.sharedWith.map(\.name))
                prefix = "Shared"
                explanation = "Used by \(names). Removing it may affect the apps that remain."
            }
        case .orphan:
            prefix = m.entry.name
            explanation = "Left behind by an app that no longer seems to be installed anywhere on this Mac, and untouched for over 30 days. Review before removing."
        }
        return ScanItem(
            url: URL(fileURLWithPath: m.entry.path), displayName: "\(prefix) · \(place)", tool: .apps,
            category: .appLeftover, sizeAllocated: report.allocatedBytes, sizeLogical: report.logicalBytes,
            fileCount: report.fileCount, lastModified: report.newestModification, tier: .review,
            explanation: explanation, ruleID: m.ruleID, cleanupMethod: .trash,
            requiresAppQuit: m.owner?.bundleID, flags: flags,
            groupID: m.owner.map { "app:\($0.bundleID)" })
    }

    private static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}
