import DiskKeeperCore
import Foundation

// Wording for the storage overview's Core codes (T40). Exhaustive switches: a new Core case can't ship without a key here.

extension StorageExplanation {
    var uiText: String {
        switch self {
        case .systemData:
            loc("storage.explain.systemData",
                "System Data is what macOS counts as neither apps, documents nor media: caches, logs, virtual-memory swap, local snapshots and other APFS volumes. macOS computes it, so this app can't match it exactly.")
        case .purgeable:
            loc("storage.explain.purgeable",
                "Purgeable space is what macOS can free on its own when it needs room. This app never deletes it. The number changes from minute to minute and can read zero even when Finder shows some.")
        case .snapshots:
            loc("storage.explain.snapshots",
                "Time Machine keeps local snapshots for about 24 hours, and macOS removes them when space is needed. This app only lists them and can't show their size. To remove them, use Time Machine settings.")
        case .whyNumbersDiffer:
            loc("storage.explain.whyNumbersDiffer",
                "Finder, System Settings and this app measure at different moments and count clones, purgeable space and snapshots differently, so the numbers rarely match exactly.")
        case .trashNeedsFullDiskAccess:
            loc("storage.explain.trashNeedsFDA",
                "macOS won't let this app look inside the Trash without Full Disk Access, so its size is unknown.")
        }
    }
}

extension LocalSnapshot.Kind {
    var uiName: String {
        switch self {
        case .timeMachine: loc("storage.snapshot.timeMachine", "Time Machine snapshot")
        case .osUpdate: loc("storage.snapshot.osUpdate", "macOS update snapshot")
        case .other: loc("storage.snapshot.other", "Other snapshot")
        }
    }
}

extension SnapshotUnavailableReason {
    var uiMessage: String {
        switch self {
        case .toolMissing: loc("storage.snapshots.toolMissing", "Couldn't run Time Machine's snapshot list.")
        case .timedOut: loc("storage.snapshots.timedOut", "Listing snapshots took too long.")
        case .failed(let status): loc("storage.snapshots.failed", "Listing snapshots failed (exit code \(Int(status))).")
        case .badVolume: loc("storage.snapshots.badVolume", "That volume path isn't valid.")
        }
    }
}

extension TrashInfo.State {
    /// nil when the Trash was measured.
    var uiMessage: String? {
        switch self {
        case .measured: nil
        case .needsFullDiskAccess: StorageExplanation.trashNeedsFullDiskAccess.uiText
        case .unavailable(let code):
            if let code {
                loc("storage.trash.unavailableErrno", "Couldn't measure the Trash (\(String(cString: strerror(code)))).")
            } else {
                loc("storage.trash.unavailable", "Couldn't measure the Trash.")
            }
        }
    }
}
