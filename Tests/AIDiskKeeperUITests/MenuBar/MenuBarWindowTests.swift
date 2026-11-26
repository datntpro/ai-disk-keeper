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
}
