import DiskKeeperCore
import Foundation

/// What a skipped or failed item offers the user next. Pure: the views map each case to a button or a sentence.
enum CleanupNextStep: Equatable {
    case rescan
    case quitApp(bundleID: String)
    case openAppManagement
    case revealInFinder
    case protected
    case tryLater
    /// The blocker's own sentence says it all.
    case sentenceOnly

    /// An exhaustive switch: a new `CleanupBlocker` fails the build until it is classified.
    static func step(for blocker: CleanupBlocker) -> CleanupNextStep {
        switch blocker {
        case .changedSinceScan, .identityChanged, .missing: .rescan
        case .appRunning(let id), .appStateUnknown(let id): .quitApp(bundleID: id)
        case .needsAppManagementPermission: .openAppManagement
        case .requiresAdmin: .revealInFinder
        case .protectedPath, .keepTier, .notActionable, .wouldRemoveAllCopies, .appBundleRefused: .protected
        case .methodNotSupported, .isSymlink, .notOwnedByUser, .symlinkInParentChain, .nestedInAnotherItem,
             .duplicate, .permanentDeleteDisabled, .sizingFailed, .survivorChanged, .duplicateGroupUnknown:
            .sentenceOnly
        }
    }

    /// The step of the first blocker that has an actionable one, else the first blocker's.
    static func step(for blockers: [CleanupBlocker]) -> CleanupNextStep {
        let steps = blockers.map(step(for:))
        return steps.first { $0 != .sentenceOnly && $0 != .protected } ?? steps.first ?? .sentenceOnly
    }

    static func step(for outcome: CleanupOutcome) -> CleanupNextStep? {
        switch outcome {
        case .skipped(let blockers): step(for: blockers)
        case .failed: .tryLater
        case .trashed, .deleted, .notAttempted: nil
        }
    }

    var text: String? {
        switch self {
        case .quitApp(let id): CleanupCopy.nextQuit(app: AppNameResolver.name(forBundleID: id))
        case .protected: CleanupCopy.nextProtected
        case .tryLater: CleanupCopy.nextTryLater
        default: nil
        }
    }

    var buttonTitle: String? {
        switch self {
        case .rescan: CleanupCopy.nextRescan
        case .openAppManagement: CleanupCopy.nextOpenSettings
        case .revealInFinder: CleanupCopy.nextReveal
        default: nil
        }
    }
}
