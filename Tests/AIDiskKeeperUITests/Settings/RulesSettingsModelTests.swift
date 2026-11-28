import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class RulesSettingsModelTests: XCTestCase {
    private var tmp: URL!
    private var env: PathEnvironment!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("adk-t23-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        env = PathEnvironment(home: tmp.path + "/home", temporaryDirectory: tmp.path + "/tmp")
        addTeardownBlock { [tmp] in try? FileManager.default.removeItem(at: tmp!) }
    }

    private func loader(counter: Counter) -> RulesSettingsModel.Loader {
        let env = self.env!
        let user = env.userRulesDirectory
        return { userOnly in
            counter.bump(userOnly)
            return RuleLoader(environment: env, bundledRulesDirectory: nil, userRulesDirectory: user,
                              guardFactory: { _ in { _ in nil } }).load()
        }
    }

    private func writeUser(_ name: String, _ json: String) throws {
        try FileManager.default.createDirectory(at: env.userRulesDirectory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: env.userRulesDirectory.appendingPathComponent(name))
    }

    func testValidateShowsInlineErrorRows() async throws {
        try writeUser("bad.json", #"{"schemaVersion":1,"tool":{"id":"u","name":"U"},"rules":[],"x":1}"#)
        let c = Counter()
        let m = RulesSettingsModel(environment: env, loader: loader(counter: c), openFolder: { _ in })
        await m.validate()
        XCTAssertEqual(c.userOnlyCalls, 1)
        XCTAssertEqual(m.problems.count, 1)
        XCTAssertEqual(m.problems[0].file, "bad.json")
        XCTAssertFalse(m.problems[0].isWarning)
        XCTAssertNotNil(m.validationSummary)
    }

    func testReloadReRunsTheLoaderAndShowsRules() async throws {
        let c = Counter()
        let m = RulesSettingsModel(environment: env, loader: loader(counter: c), openFolder: { _ in })
        await m.reload()
        XCTAssertTrue(m.files.isEmpty)
        let rule = #"{"id":"u.r","title":"My cache","category":"aiToolData","paths":["~/.u/c"],"match":{"kind":"self"},"tier":"safe","explanation":"x"}"#
        try writeUser("good.json", #"{"schemaVersion":1,"tool":{"id":"u","name":"U"},"rules":[\#(rule)]}"#)
        await m.reload()
        XCTAssertEqual(c.fullCalls, 2)
        XCTAssertEqual(m.files.map(\.rules.first?.id), ["u.r"])
        XCTAssertEqual(m.files[0].source, .user)
        XCTAssertEqual(m.problems.filter(\.isWarning).count, 1, "the Safe→Review cap is shown as a warning")
        XCTAssertNil(m.validationSummary)
    }

    func testOpenFolderCreatesItOnlyOnUserAction() throws {
        let opened = Box()
        let m = RulesSettingsModel(environment: env, loader: loader(counter: Counter()), openFolder: { opened.url = $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.userRulesDirectory.path))
        m.openRulesFolder()
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.userRulesDirectory.path))
        XCTAssertEqual(opened.url, env.userRulesDirectory)
    }

    func testContextMenuOffersOnlyStricterTiers() {
        XCTAssertEqual(UserPolicyChoices.offered(for: .safe), [.review, .keep])
        XCTAssertEqual(UserPolicyChoices.offered(for: .review), [.keep])
        XCTAssertEqual(UserPolicyChoices.offered(for: .keep), [])
    }

    func testSettingsModelRefusesLooserOverrideAndResets() {
        let url = tmp.appendingPathComponent("settings.json")
        let m = SettingsModel(store: SettingsStore(fileURL: url), environment: env, probe: { .unknown })
        let review = ScanItem(url: URL(fileURLWithPath: env.home + "/x"), displayName: "x", tool: "t", category: .aiToolData,
                              sizeAllocated: 1, sizeLogical: 1, fileCount: 1, lastModified: nil, tier: .review,
                              explanation: "x", ruleID: "t.r")
        m.overrideTier(of: review, to: .safe)
        XCTAssertTrue(m.settings.tierOverrides.isEmpty)
        m.overrideTier(of: review, to: .keep)
        XCTAssertEqual(m.settings.tierOverrides[review.id], .keep)
        m.ignoreItem(review.id)
        m.setRule("t.r", disabled: true)
        let reloaded = SettingsModel(store: SettingsStore(fileURL: url), environment: env, probe: { .unknown }).settings
        XCTAssertEqual(reloaded.ignoredItemIDs, [review.id])
        XCTAssertEqual(reloaded.disabledRuleIDs, ["t.r"])
        m.resetOverride(review.id); m.unignoreItem(review.id)
        XCTAssertTrue(m.settings.tierOverrides.isEmpty && m.settings.ignoredItemIDs.isEmpty)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var user = 0, full = 0
        func bump(_ userOnly: Bool) { lock.lock(); if userOnly { user += 1 } else { full += 1 }; lock.unlock() }
        var userOnlyCalls: Int { lock.lock(); defer { lock.unlock() }; return user }
        var fullCalls: Int { lock.lock(); defer { lock.unlock() }; return full }
    }
    final class Box { var url: URL? }
}
