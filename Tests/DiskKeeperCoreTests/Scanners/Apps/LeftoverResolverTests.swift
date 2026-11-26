import XCTest
@testable import DiskKeeperCore

final class LeftoverResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { now.addingTimeInterval(-90 * 86_400) }
    private var recent: Date { now.addingTimeInterval(-2 * 86_400) }
    private let lib = "/fixture/Library"

    private func e(_ loc: LibraryLocation, _ name: String, dir: Bool = true, modified: Date? = nil,
                   label: String? = nil, program: String? = nil) -> LibraryEntry {
        LibraryEntry(location: loc, name: name, path: "\(lib)/\(loc.rawValue)/\(name)", isDirectory: dir,
                     modified: modified ?? old, launchLabel: label, launchProgram: program)
    }

    private func resolve(_ apps: [InstalledApp], _ entries: [LibraryEntry],
                         lookup: @escaping (String) -> Bool? = { _ in false }) -> [LeftoverMatch] {
        LeftoverResolver.resolve(apps: apps, index: LibraryIndex(entries: entries), now: now, isInstalledAnywhere: lookup)
    }

    private let foo = AppFixtures.app("com.foo.app", name: "Foo")

    func testExactLocations() {
        let entries = [
            e(.applicationSupport, "com.foo.app"), e(.caches, "com.foo.app"), e(.containers, "com.foo.app"),
            e(.httpStorages, "com.foo.app"), e(.webKit, "com.foo.app"), e(.logs, "com.foo.app"),
            e(.preferences, "com.foo.app.plist", dir: false),
            e(.preferencesByHost, "com.foo.app.A1B2C3D4-0000.plist", dir: false),
            e(.savedState, "com.foo.app.savedState"),
            e(.groupContainers, "TEAM123456.com.foo.app"),
            e(.cookies, "com.foo.app.binarycookies", dir: false),
        ]
        let m = resolve([foo], entries)
        XCTAssertEqual(m.count, entries.count)
        XCTAssertTrue(m.allSatisfy { $0.level == .exact && $0.owner?.bundleID == "com.foo.app" })
    }

    func testFoldingNFDAndMixedCase() {
        let app = AppFixtures.app("com.Foo.App", name: "Foo")
        let m = resolve([app], [e(.containers, "com.foo.app"), e(.caches, "COM.FOO.APP")])
        XCTAssertEqual(m.map(\.level), [.exact, .exact])
        let nfd = AppFixtures.app("com.t.cafe", name: "Caf\u{e9}")   // NFC name
        let n = resolve([nfd], [e(.applicationSupport, "Cafe\u{301}")])
        XCTAssertEqual(n.first?.level, .name)
    }

    func testNameLevelOnlyForSupportCachesLogs() {
        let m = resolve([foo], [e(.applicationSupport, "Foo"), e(.caches, "foo"), e(.logs, "FOO"),
                                e(.containers, "Foo"), e(.preferences, "Foo.plist", dir: false)])
        XCTAssertEqual(m.map(\.level), [.name, .name, .name])
        XCTAssertTrue(m.allSatisfy { $0.owner?.bundleID == "com.foo.app" })
    }

    func testBundleNameAlsoMatches() {
        let app = AppFixtures.app("com.t.long", name: "Long Display Name", bundleName: "LongApp")
        XCTAssertEqual(resolve([app], [e(.applicationSupport, "LongApp")]).first?.level, .name)
    }

    func testStoplistShortAndAppleNamesNeverMatch() {
        let google = AppFixtures.app("com.t.g", name: "Google")
        let data = AppFixtures.app("com.t.d", name: "Data")
        let ab = AppFixtures.app("com.t.ab", name: "AB")
        let appleMail = AppFixtures.app("com.apple.mail", name: "Mail", source: .apple)
        let thirdMail = AppFixtures.app("com.t.mail", name: "Mail")
        let m = resolve([google, data, ab, appleMail, thirdMail],
                        [e(.applicationSupport, "Google"), e(.caches, "Data"), e(.caches, "AB"), e(.applicationSupport, "Mail")],
                        lookup: { _ in nil })
        XCTAssertTrue(m.isEmpty, "\(m)")
    }

    func testLongestBundleIDWins() {
        let helper = AppFixtures.app("com.foo.app.helper", name: "Helper")
        let m = resolve([foo, helper], [e(.preferences, "com.foo.app.helper.plist", dir: false),
                                        e(.containers, "com.foo.app.helper"), e(.containers, "com.foo.app")])
        XCTAssertEqual(m.first { $0.entry.name == "com.foo.app.helper.plist" }?.owner?.bundleID, "com.foo.app.helper")
        XCTAssertEqual(m.first { $0.entry.name == "com.foo.app.helper" }?.owner?.bundleID, "com.foo.app.helper")
        XCTAssertEqual(m.first { $0.entry.name == "com.foo.app" }?.owner?.bundleID, "com.foo.app")
    }

    func testSharedGroupContainerIsNameLevelAndUnattached() {
        let a = AppFixtures.app("com.foo.a", name: "A")
        let b = AppFixtures.app("com.foo.b", name: "B")
        let m = resolve([a, b], [e(.groupContainers, "TEAM123456.group.shared"), e(.groupContainers, "TEAM123456.com.foo.a")])
        let shared = m.first { $0.entry.name == "TEAM123456.group.shared" }
        XCTAssertEqual(shared?.level, .name)
        XCTAssertNil(shared?.owner)
        XCTAssertEqual(shared?.sharedWith.map(\.name), ["A", "B"])
        XCTAssertEqual(m.first { $0.entry.name == "TEAM123456.com.foo.a" }?.level, .exact)
    }

    func testSingleAppTeamGroupContainerIsNameLevelNotExact() {
        let m = resolve([foo], [e(.groupContainers, "TEAM123456.group.data")])
        XCTAssertEqual(m.first?.level, .name)
        XCTAssertEqual(m.first?.owner?.bundleID, "com.foo.app")
    }

    func testGroupContainerWithWrongTeamIsNotExact() {
        let m = resolve([foo], [e(.groupContainers, "OTHERTEAM1.com.foo.app")])
        XCTAssertNotEqual(m.first?.level, .exact)
    }

    func testNameMatchedByTwoAppsIsSharedOnce() {
        let a = AppFixtures.app("com.t.one", name: "Studio")
        let b = AppFixtures.app("com.t.two", name: "Studio", bundleName: "Studio")
        let m = resolve([a, b], [e(.applicationSupport, "Studio")])
        XCTAssertEqual(m.count, 1)
        XCTAssertNil(m[0].owner)
        XCTAssertEqual(m[0].sharedWith.count, 2)
    }

    func testAppleNeverProducesLeftoversOrOrphans() {
        let safari = AppFixtures.app("com.apple.Safari", name: "Safari", source: .apple)
        let m = resolve([safari], [e(.containers, "com.apple.Safari"), e(.caches, "Safari"),
                                   e(.containers, "com.apple.old.thing"), e(.caches, "com.apple.foo.bar")])
        XCTAssertTrue(m.isEmpty)
    }

    func testLaunchAgentByLabelAndByProgram() {
        let app = AppFixtures.app("com.foo.app", name: "Foo", path: "/Applications/Foo.app")
        let m = resolve([app], [
            e(.launchAgents, "x.plist", dir: false, label: "com.foo.app.updater"),
            e(.launchAgents, "y.plist", dir: false, label: "unrelated", program: "/Applications/Foo.app/Contents/MacOS/helper"),
            e(.launchAgents, "z.plist", dir: false, label: "com.other.thing", program: "/Applications/Other.app/x"),
            e(.launchAgents, "com.foo.app.plist", dir: false),
        ])
        XCTAssertEqual(Set(m.map(\.entry.name)), ["x.plist", "y.plist", "com.foo.app.plist"])
        XCTAssertTrue(m.allSatisfy { $0.level == .exact })
    }

    func testOrphanRules() {
        let ids = ["com.gone.tool", "com.old.app"]
        _ = ids
        let entries = [
            e(.containers, "com.gone.tool"),                                  // orphan
            e(.preferences, "com.gone.prefs.plist", dir: false),             // orphan
            e(.savedState, "com.gone.state.savedState"),                      // orphan
            e(.containers, "com.gone.prefs"), e(.containers, "com.gone.state"),   // evidence for the two above
            e(.caches, "com.new.recent", modified: recent),                   // too new
            e(.caches, "com.known.installed"),                                // LS knows it
            e(.caches, "com.unknown.lookup"),                                 // LS nil
            e(.caches, "ab.cd"),                                              // < 3 components
            e(.launchAgents, "com.gone.agent.plist", dir: false),             // LaunchAgents are T38's
            e(.groupContainers, "TEAM123456.com.gone.group"),                 // not an orphan location
            e(.caches, "com.foo.app.extra"),                                  // claimed by installed com.foo.app
            e(.caches, "Not A Bundle Id"),
        ]
        let m = resolve([foo], entries, lookup: {
            switch $0 {
            case "com.known.installed": true
            case "com.unknown.lookup": nil
            default: false
            }
        })
        XCTAssertEqual(Set(m.filter { $0.level == .orphan }.map(\.entry.name)),
                       ["com.gone.tool", "com.gone.prefs.plist", "com.gone.state.savedState", "com.gone.prefs", "com.gone.state"])
        // The one claimed by com.foo.app is a normal exact (prefix) owner only when it is its own id; here it is not exact.
        XCTAssertFalse(m.contains { $0.entry.name == "com.foo.app.extra" && $0.level == .orphan })
    }

    func testOrphanLaunchServicesMustSayFalse() {
        let entries = [e(.containers, "com.gone.tool")]
        XCTAssertEqual(resolve([], entries, lookup: { _ in false }).count, 1)
        XCTAssertEqual(resolve([], entries, lookup: { _ in true }).count, 0)
        XCTAssertEqual(resolve([], entries, lookup: { _ in nil }).count, 0)
    }

    func testEachPathEmittedOnce() {
        let a = AppFixtures.app("com.foo.app", name: "Foo")
        let dup = AppFixtures.app("com.foo.app", name: "Foo", path: "/Users/x/Applications/Foo.app")
        XCTAssertEqual(resolve([a, dup], [e(.containers, "com.foo.app")]).count, 1)
    }

    // B1: cookies files of installed apps
    func testBinaryCookiesOfInstalledAppAreExactNotOrphans() {
        let m = resolve([foo], [e(.httpStorages, "com.foo.app.binarycookies", dir: false),
                                e(.httpStorages, "com.foo.app")])
        XCTAssertEqual(m.map(\.level), [.exact, .exact])
        // Installed elsewhere (not in the inventory): LaunchServices says true, so never an orphan.
        let m2 = resolve([], [e(.httpStorages, "com.microsoft.SharePoint-mac.binarycookies", dir: false),
                              e(.containers, "com.microsoft.SharePoint-mac")], lookup: { _ in true })
        XCTAssertTrue(m2.isEmpty)
        // Even with no LaunchServices answer for the stripped id, the extension is not part of the id.
        let m3 = resolve([], [e(.httpStorages, "com.gone.tool.binarycookies", dir: false), e(.containers, "com.gone.tool")],
                         lookup: { $0 == "com.gone.tool.binarycookies" ? true : false })
        XCTAssertEqual(m3.count, 2)
    }

    // B2: extension containers whose host is installed elsewhere
    func testExtensionContainerWithInstalledHostIsNotAnOrphan() {
        let entries = [e(.containers, "com.macwall.ogapps.extension")]
        XCTAssertTrue(resolve([], entries, lookup: { $0 == "com.macwall.ogapps" }).isEmpty)
        XCTAssertTrue(resolve([], entries, lookup: { $0 == "com.macwall.ogapps" ? nil : false }).isEmpty)
        XCTAssertEqual(resolve([], entries, lookup: { _ in false }).count, 1)
        // 2-component hosts are never asked about (too generic).
        var asked: [String] = []
        _ = resolve([], entries, lookup: { asked.append($0); return false })
        XCTAssertEqual(asked, ["com.macwall.ogapps.extension", "com.macwall.ogapps"])
    }

    // B3: CLI / framework caches
    func testToolAndFrameworkCachesAreNeverOrphans() {
        let entries = [
            e(.caches, "org.swift.swiftpm"), e(.caches, "com.plausiblelabs.crashreporter.data"),
            e(.containers, "org.swift.swiftpm"),                  // even with a container: known non-app prefix
            e(.caches, "com.unknown.cacheonly"),                  // looks like an app id but nothing says an app existed
            e(.containers, "com.gone.real"), e(.caches, "com.gone.real"),
        ]
        let m = resolve([], entries)
        XCTAssertEqual(Set(m.map(\.entry.path)), Set(entries.filter { $0.name == "com.gone.real" }.map(\.path)))
    }

    // N2
    func testAppleBundleIDIsNeverAnOrphanEvenFromAppStore() {
        let m = resolve([], [e(.containers, "com.apple.dt.Xcode.helper")])
        XCTAssertTrue(m.isEmpty)
    }
}
