import SwiftUI

/// The Software updates rows of a personal build: automatic checks and
/// builds, the Chromium engine's standing, and the check or its progress.
struct SourceUpdateSettingsSection: View {
    let source: BrowserSourceUpdateService

    @Environment(BrowserSoftwareUpdateService.self) private var softwareUpdates

    var body: some View {
        Section {
            Toggle(
                "Check upstream for changes automatically",
                isOn: Binding(
                    get: { source.automaticallyChecksForUpdates },
                    set: source.setAutomaticallyChecksForUpdates
                )
            )

            Toggle(
                "Build updates automatically",
                isOn: Binding(
                    get: { source.automaticallyBuildsUpdates },
                    set: source.setAutomaticallyBuildsUpdates
                )
            )
            .disabled(!source.automaticallyChecksForUpdates)

            VStack(alignment: .leading, spacing: CrestSpacing.extraExtraSmall) {
                Text("Chromium engine")
                Text(verbatim: source.engineSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if softwareUpdates.model.phase == .idle {
                HStack {
                    Spacer()
                    Button("Check for Updates…") {
                        softwareUpdates.checkForUpdates()
                    }
                    .disabled(!softwareUpdates.isEnabled || source.isChecking || source.isBuilding)
                }
            } else {
                BrowserSoftwareUpdateStatusRow(model: softwareUpdates.model)
                BrowserSoftwareUpdateActions(model: softwareUpdates.model, confirmsWithReturn: false)
            }
        } header: {
            Text("Software updates")
        } footer: {
            Text(verbatim: source.guidance).crestFormFootnote()
        }
    }
}
