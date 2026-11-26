import AppKit
import DiskKeeperCore
import SwiftUI

/// App icons by path (reads only). Main-actor, so a plain dictionary is enough.
@MainActor enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

extension UninstallerModel {
    /// The second line of an app row, from what we know about it.
    func caption(for app: InstalledApp) -> String {
        if app.viewOnlyReason == .apple || app.source == .apple { return UninstallerCopy.apple }
        if isRunning(app) { return UninstallerCopy.runningNow }
        if app.viewOnlyReason == .notOwnedByUser { return UninstallerCopy.allUsers }
        let opened = app.lastUsed.map { UninstallerCopy.lastOpened(Formatting.relative($0)) } ?? UninstallerCopy.neverOpened
        if case .appStore = app.source { return UninstallerCopy.appStore(opened) }
        return opened
    }
}

struct UninstallAppList: View {
    @Bindable var model: UninstallerModel

    var body: some View {
        let rows = model.filteredApps
        Group {
            if rows.isEmpty && !model.search.isEmpty {
                StateView(kind: .empty, symbol: "magnifyingglass", title: UninstallerCopy.noMatch(model.search), message: "",
                          actions: [StateAction(title: UninstallerCopy.clearSearch) { model.search = "" }])
            } else {
                List(selection: Binding(get: { model.selectedAppID }, set: { id in
                    if let id, let app = model.apps.first(where: { $0.id == id }) { model.select(app) }
                })) {
                    ForEach(rows) { app in row(app).tag(app.id) }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: UninstallerCopy.search)
    }

    private func row(_ app: InstalledApp) -> some View {
        let locked = app.viewOnlyReason != nil
        let running = model.isRunning(app)
        let caption = model.caption(for: app)
        return HStack(spacing: ADKTheme.Spacing.md) {
            Image(nsImage: AppIconCache.icon(for: app.path)).resizable().frame(width: 28, height: 28)
                .opacity(locked ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(running ? .adkReviewInk : .adkText3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ADKTheme.Spacing.sm)
            if locked { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.adkText3).accessibilityHidden(true) }
            SizeText(app.sizeAllocated).font(.callout).foregroundStyle(.adkText2)
        }
        .foregroundStyle(locked ? .adkText2 : .adkText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UninstallerCopy.a11yApp(app.name, caption, SizeText.string(app.sizeAllocated, .exact)))
    }
}
