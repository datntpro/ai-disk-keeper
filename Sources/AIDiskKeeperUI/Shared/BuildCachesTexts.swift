import DiskKeeperCore
import Foundation

enum BuildCachesCopy {
    static var hintsTitle: String { loc("caches.hints.title", "Run this in Terminal if you want the tool to clean itself:") }
    static var copyCommand: String { loc("caches.hints.copy", "Copy command") }
    static func copyCommandA11y(_ command: String) -> String { loc("caches.hints.copy.a11y", "Copy command: \(command)") }
    static var reportOnly: String { loc("caches.vms.reportOnly", "Report only: delete VMs with tart delete") }

    static func family(_ f: BuildCacheCatalog.Family) -> String {
        switch f {
        case .xcode: loc("caches.family.xcode", "Xcode")
        case .javascript: loc("caches.family.javascript", "JavaScript")
        case .go: loc("caches.family.go", "Go")
        case .rust: loc("caches.family.rust", "Rust")
        case .jvm: loc("caches.family.jvm", "JVM")
        case .swift: loc("caches.family.swift", "Swift")
        case .python: loc("caches.family.python", "Python")
        case .vms: loc("caches.family.vms", "VMs")
        case .other: loc("caches.family.other", "Other")
        }
    }
}

/// Translated explanations for the DerivedData scanner's items (the rules in `build-caches.json` carry their own `vi`).
enum BuildCachesTexts: Sendable {
    nonisolated static func text(for item: ScanItem) -> ScannerTexts.Text? {
        if let variant = DerivedDataVariant.of(item) { return ScannerTexts.Text(name: nil, explanation: explanation(variant)) }
        if let variant = TartTmpVariant.of(item) { return ScannerTexts.Text(name: nil, explanation: explanation(variant)) }
        return nil
    }

    nonisolated static func explanation(_ v: TartTmpVariant) -> String {
        switch v {
        case .active:
            loc("caches.tmp.active", "Regenerable: a partial download or scratch file Tart is writing or wrote in the last day. A pull or clone may be using it. Kept.")
        case .old:
            loc("caches.tmp.old", "Regenerable: a partial download or scratch file Tart left behind when a pull or clone was interrupted. Tart starts it again.")
        }
    }

    nonisolated static func explanation(_ v: DerivedDataVariant) -> String {
        switch v {
        case .active:
            loc("caches.dd.active", "Regenerable: build output for an Xcode project. It changed in the last day, so a build or the editor may be using it. Kept.")
        case .projectGone:
            loc("caches.dd.gone", "Regenerable: build output, indexes and logs for an Xcode project that no longer exists on this Mac. Nothing will ask for it again, and Xcode rebuilds it if the project comes back.")
        case .projectGoneRecent:
            loc("caches.dd.goneRecent", "Regenerable: build output for an Xcode project that was removed or moved less than a week ago. Xcode rebuilds it if the project comes back, so check that you do not still need the project first.")
        case .projectExists:
            loc("caches.dd.exists", "Regenerable: build output, indexes and logs for an Xcode project that still exists. Xcode rebuilds it, so the next build of that project is slower and its indexing starts again.")
        case .unreadable:
            loc("caches.dd.unreadable", "Regenerable: build output for an Xcode project, but Disk Keeper couldn't read the project path from this folder, so it can't tell whether the project still exists. Xcode rebuilds it on the next build.")
        }
    }
}
