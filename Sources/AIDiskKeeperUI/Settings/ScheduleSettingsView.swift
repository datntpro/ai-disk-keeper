import AppKit
import DiskKeeperCore
import SwiftUI

/// Settings → Schedule (T22).
struct ScheduleSettingsView: View {
    let model: SettingsModel
    @State private var loginStatus: LoginItemStatus
    @State private var loginError: String?
    private let loginItem: any LoginItemControlling

    init(model: SettingsModel, loginItem: any LoginItemControlling = LiveLoginItem()) {
        self.model = model
        self.loginItem = loginItem
        _loginStatus = State(initialValue: loginItem.status)
    }

    private var s: AppSettings { model.settings }

    var body: some View {
        Form {
            Section(ScheduleCopy.section) {
                Picker(ScheduleCopy.frequency, selection: Binding(get: { s.scanFrequency }, set: { model.setScanFrequency($0) })) {
                    Text(ScheduleCopy.off).tag(ScanFrequency.off)
                    Text(ScheduleCopy.daily).tag(ScanFrequency.daily)
                    Text(ScheduleCopy.weekly).tag(ScanFrequency.weekly)
                }
                Text(ScheduleCopy.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if s.scanFrequency != .off {
                    Stepper(value: Binding(get: { s.scheduledSafeAlertGB }, set: { model.setScheduledSafeAlertGB($0) }), in: 1...500) {
                        Text("\(ScheduleCopy.safeThreshold): \(Formatting.count(s.scheduledSafeAlertGB))")
                    }
                    Stepper(value: Binding(get: { s.scheduledGrowthAlertGB }, set: { model.setScheduledGrowthAlertGB($0) }), in: 1...500) {
                        Text("\(ScheduleCopy.growthThreshold): \(Formatting.count(s.scheduledGrowthAlertGB))")
                    }
                    Toggle(ScheduleCopy.skipOnBattery, isOn: Binding(get: { s.scheduledSkipOnBattery }, set: { model.setScheduledSkipOnBattery($0) }))
                }
            }
            Section {
                Toggle(ScheduleCopy.loginItem, isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: setLogin))
                    .disabled(loginStatus == .unavailable)
                switch loginStatus {
                case .requiresApproval:
                    Text(ScheduleCopy.loginNeedsApproval).font(.caption).foregroundStyle(.secondary)
                    Button(ScheduleCopy.openLoginSettings) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                case .unavailable:
                    Text(ScheduleCopy.loginUnavailable).font(.caption).foregroundStyle(.secondary)
                default: EmptyView()
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do {
            try loginItem.setEnabled(on)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = loginItem.status
    }
}
