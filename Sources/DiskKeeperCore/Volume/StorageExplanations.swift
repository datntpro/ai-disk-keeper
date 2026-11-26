import Foundation

/// What the storage numbers mean. Core owns the topics and the English text (CLI, docs, logs);
/// the UI words each topic through the string catalog (`storage.explain.*`, English and Vietnamese).
public enum StorageExplanation: String, Sendable, CaseIterable {
    case systemData, purgeable, snapshots, whyNumbersDiffer, trashNeedsFullDiskAccess

    public var englishText: String {
        switch self {
        case .systemData:
            "System Data is what macOS counts as neither apps, documents nor media: caches, logs, virtual-memory swap, local snapshots and other APFS volumes. macOS computes it, so this app can't match it exactly."
        case .purgeable:
            "Purgeable space is what macOS can free on its own when it needs room. This app never deletes it. The number changes from minute to minute and can read zero even when Finder shows some."
        case .snapshots:
            "Time Machine keeps local snapshots for about 24 hours, and macOS removes them when space is needed. This app only lists them and can't show their size. To remove them, use Time Machine settings."
        case .whyNumbersDiffer:
            "Finder, System Settings and this app measure at different moments and count clones, purgeable space and snapshots differently, so the numbers rarely match exactly."
        case .trashNeedsFullDiskAccess:
            "macOS won't let this app look inside the Trash without Full Disk Access, so its size is unknown."
        }
    }
}
