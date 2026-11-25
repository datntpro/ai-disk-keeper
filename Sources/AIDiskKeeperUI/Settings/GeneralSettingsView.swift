import SwiftUI

struct GeneralSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            if let warning = model.loadWarning {
                HStack {
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Dismiss") { model.dismissLoadWarning() }
                }
            }
            FullDiskAccessCard(status: model.fdaStatus, recheck: model.refreshFullDiskAccess)
            Divider()
            Button("Show welcome screen again") { model.setOnboardingCompleted(false) }
        }
        .padding(20)
    }
}
