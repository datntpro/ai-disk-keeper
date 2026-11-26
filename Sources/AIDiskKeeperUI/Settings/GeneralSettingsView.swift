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
            menuBarSection
            FullDiskAccessCard(status: model.fdaStatus, recheck: model.refreshFullDiskAccess)
            Button(loc("settings.general.showWelcome", "Show welcome screen again")) { model.setOnboardingCompleted(false) }
        }
        .formStyle(.grouped)
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

    private var menuBarSection: some View {
        Section(loc("settings.menubar.section", "Menu bar")) {
            Toggle(loc("settings.menubar.show", "Show in menu bar"), isOn: Binding(
                get: { model.settings.showMenuBarItem }, set: { model.setShowMenuBarItem($0) }))
            Toggle(loc("settings.menubar.freeText", "Show free space next to the icon"), isOn: Binding(
                get: { model.settings.menuBarShowsFreeSpace }, set: { model.setMenuBarShowsFreeSpace($0) }))
                .disabled(!model.settings.showMenuBarItem)
            Toggle(loc("settings.menubar.lowSpace", "Alert me when free space is low"), isOn: Binding(
                get: { model.settings.lowSpaceAlertEnabled }, set: { model.setLowSpaceAlertEnabled($0) }))
            if model.settings.lowSpaceAlertEnabled {
                Stepper(loc("settings.menubar.threshold", "Below \(Formatting.count(model.settings.lowSpaceThresholdPercent)) %"),
                        value: Binding(get: { model.settings.lowSpaceThresholdPercent },
                                       set: { model.setLowSpaceThresholdPercent($0) }),
                        in: AppSettings.lowSpaceThresholdRange)
                Text(loc("settings.menubar.thresholdHelp", "One notification each time free space drops below this level."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
