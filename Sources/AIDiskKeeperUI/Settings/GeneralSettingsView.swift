import AppKit
import DiskKeeperCore
import SwiftUI

struct GeneralSettingsView: View {
    let model: SettingsModel
    @State private var languageChanged = false

    var body: some View {
        Form {
            if let warning = model.loadWarning {
                HStack {
                    Label(warning.uiMessage, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button(loc("settings.general.dismiss", "Dismiss")) { model.dismissLoadWarning() }
                }
            }
            languageSection
            cacheSection
            FullDiskAccessCard(status: model.fdaStatus, recheck: model.refreshFullDiskAccess)
            Button(loc("settings.general.showWelcome", "Show welcome screen again")) { model.setOnboardingCompleted(false) }
        }
        .formStyle(.grouped)
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(loc("settings.cache.toggle", "Speed up rescans with a cache"), isOn: Binding(
                get: { model.settings.useScanCache }, set: { model.setUseScanCache($0) }))
            HStack {
                Button(loc("settings.cache.clear", "Clear scan cache")) { model.clearScanCache() }
                if model.scanCacheCleared {
                    Text(loc("settings.cache.cleared", "Scan cache cleared")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(loc("settings.general.language", "Language"), selection: Binding(
                get: { model.language },
                set: { model.setLanguage($0); languageChanged = true })) {
                // Language names are shown in their own language, never translated.
                Text(loc("settings.general.language.system", "System (\(Self.endonym(L10n.resolve(.system).language)))"))
                    .tag(AppLanguage.system)
                Text(verbatim: Self.endonym("en")).tag(AppLanguage.en)
                Text(verbatim: Self.endonym("vi")).tag(AppLanguage.vi)
            }
            Text(loc("settings.general.language.menusNote", "Menus provided by macOS switch after you relaunch."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if languageChanged, Bundle.main.bundleURL.pathExtension == "app" {
                Button(loc("settings.general.relaunch", "Relaunch now")) { Self.relaunch() }
            }
        }
    }

    static func endonym(_ code: String) -> String {
        switch code {
        case "vi": "Tiếng Việt"
        default: "English"
        }
    }

    private static func relaunch() {
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        NSApp.terminate(nil)
    }
}
