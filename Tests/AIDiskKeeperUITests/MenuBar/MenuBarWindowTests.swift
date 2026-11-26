import XCTest

/// "Review in app" calls `openWindow(id: "main")`. That reuses the one window only if the scene is a single `Window`;
/// a `WindowGroup` opens another window on every click.
final class MenuBarWindowTests: XCTestCase {
    func testMainSceneIsASingleWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/AIDiskKeeper/AIDiskKeeperApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains(#"Window(Text(verbatim: "AI Disk Keeper"), id: "main")"#))
        XCTAssertFalse(app.contains("WindowGroup"), "a WindowGroup would open a second window per Review in app click")
        let popover = try String(contentsOf: root.appendingPathComponent("Sources/AIDiskKeeperUI/MenuBar/MenuBarPopover.swift"), encoding: .utf8)
        XCTAssertTrue(popover.contains(#"openWindow(id: "main")"#))
    }

    /// Regression: a `return WindowGroup {…}` in a scene builder made the `Settings { … }` line after it dead code,
    /// so ⌘, and "Settings…" did nothing. The scene builders must not `return`, and the Settings scene must exist.
    func testSettingsSceneIsRegisteredAndNoSceneBuilderReturns() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/AIDiskKeeper/AIDiskKeeperApp.swift"), encoding: .utf8)
        let returns = try NSRegularExpression(pattern: #"(?m)^\s*return\s+(Window|WindowGroup|Settings|MenuBarExtra)\b"#)
        XCTAssertNil(returns.firstMatch(in: app, range: NSRange(app.startIndex..., in: app)), "return in a scene builder drops later scenes")
        XCTAssertTrue(app.contains("@SceneBuilder private var mainScenes"))
        XCTAssertTrue(app.contains("Settings { SettingsView("))
        XCTAssertTrue(app.contains("mainScenes") && app.contains("menuBarScene"))
        XCTAssertTrue(app.contains("var body: some Scene {\n        mainScenes\n        menuBarScene"))
    }
}
