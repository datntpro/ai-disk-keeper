import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class CleanupNextStepTests: XCTestCase {
    func testEveryBlockerMapsToItsStep() {
        let detail = ChangeDetail(scannedBytes: 1, currentBytes: 2, scannedModified: nil, currentModified: nil)
        let table: [(CleanupBlocker, CleanupNextStep)] = [
            (.keepTier, .protected),
            (.notActionable, .protected),
            (.methodNotSupported("x"), .sentenceOnly),
            (.protectedPath(.protectedPath, message: "m"), .protected),
            (.missing, .rescan),
            (.isSymlink, .sentenceOnly),
            (.notOwnedByUser(uid: 0), .sentenceOnly),
            (.symlinkInParentChain(resolvedParent: "/x"), .sentenceOnly),
            (.identityChanged, .rescan),
            (.changedSinceScan(detail), .rescan),
            (.appRunning(bundleID: "com.a.b"), .quitApp(bundleID: "com.a.b")),
            (.appStateUnknown(bundleID: "com.a.b"), .quitApp(bundleID: "com.a.b")),
            (.nestedInAnotherItem(otherItemID: "o"), .sentenceOnly),
            (.duplicate, .sentenceOnly),
            (.permanentDeleteDisabled, .sentenceOnly),
            (.sizingFailed("e"), .sentenceOnly),
            (.wouldRemoveAllCopies(groupID: "g"), .protected),
            (.survivorChanged(groupID: "g"), .sentenceOnly),
            (.duplicateGroupUnknown(groupID: "g"), .sentenceOnly),
            (.appBundleRefused(.appleOrSystem), .protected),
            (.requiresAdmin(bundleID: "com.a.b"), .revealInFinder),
            (.needsAppManagementPermission(bundleID: "com.a.b"), .openAppManagement),
        ]
        for (blocker, expected) in table {
            XCTAssertEqual(CleanupNextStep.step(for: blocker), expected, "\(blocker)")
        }
    }

    func testOutcomes() {
        XCTAssertEqual(CleanupNextStep.step(for: .failed("boom")), .tryLater)
        XCTAssertNil(CleanupNextStep.step(for: .trashed(trashPath: nil)))
        XCTAssertNil(CleanupNextStep.step(for: .notAttempted))
        XCTAssertEqual(CleanupNextStep.step(for: .skipped([.keepTier, .missing])), .rescan, "actionable step wins")
    }

    func testCopy() {
        XCTAssertNotNil(CleanupNextStep.rescan.buttonTitle)
        XCTAssertNil(CleanupNextStep.rescan.text)
        XCTAssertNotNil(CleanupNextStep.tryLater.text)
        XCTAssertNil(CleanupNextStep.sentenceOnly.text)
    }
}
