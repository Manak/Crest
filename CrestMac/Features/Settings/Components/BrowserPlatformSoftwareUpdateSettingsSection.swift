import SwiftUI

struct BrowserPlatformSoftwareUpdateSettingsSection: View {
    // MARK: - Variables

    @Environment(BrowserSoftwareUpdateService.self) private var softwareUpdates

    var body: some View {
        if let source = softwareUpdates.source {
            sourceSection(source)
        } else {
            feedSection
        }
    }

    /// Updates for a personal build, from its Git checkout.
    private func sourceSection(_ source: BrowserSourceUpdateService) -> some View {
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

    /// Updates for the official app, from its Sparkle feed.
    private var feedSection: some View {
        Section {
            Toggle(
                "Check for updates automatically",
                isOn: Binding(
                    get: { softwareUpdates.automaticallyChecksForUpdates },
                    set: softwareUpdates.setAutomaticallyChecksForUpdates
                )
            )

            Toggle(
                "Download and install updates automatically",
                isOn: Binding(
                    get: { softwareUpdates.automaticallyDownloadsUpdates },
                    set: softwareUpdates.setAutomaticallyDownloadsUpdates
                )
            )
            .disabled(!softwareUpdates.automaticallyChecksForUpdates)

            Picker(
                "Update channel",
                selection: Binding(
                    get: { softwareUpdates.channel },
                    set: { softwareUpdates.channel = $0 }
                )
            ) {
                ForEach(BrowserSoftwareUpdateChannel.offered) { channel in
                    Text(channel.title).tag(channel)
                }
            }

            if softwareUpdates.model.phase == .idle {
                HStack {
                    Spacer()
                    Button("Check for Updates…") {
                        softwareUpdates.checkForUpdates()
                    }
                    .disabled(!softwareUpdates.isEnabled)
                }
            } else {
                BrowserSoftwareUpdateStatusRow(model: softwareUpdates.model)
                BrowserSoftwareUpdateActions(model: softwareUpdates.model, confirmsWithReturn: false)
            }

            if let startErrorDescription = softwareUpdates.startErrorDescription {
                Label(
                    startErrorDescription,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Software updates")
        } footer: {
            Text(softwareUpdates.channel.guidance).crestFormFootnote()
        }
    }
}
