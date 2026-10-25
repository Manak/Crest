import SwiftUI

/// The plugins this build carries: each one's switch, version and standing,
/// and the hooks this Crest could not take.
struct BrowserPluginsSettingsPane: View {
    @Environment(CrestPluginHost.self) private var host

    var body: some View {
        BrowserSettingsPane(.plugins) {
            Section {
                summary
            }

            Section {
                if host.records.isEmpty {
                    Text("This build carries no plugins.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(host.records) { record in
                        BrowserPluginSettingsRow(record: record) { isEnabled in
                            host.setEnabled(isEnabled, for: record.id)
                        }
                    }
                }
            } header: {
                Text("Plugins")
            } footer: {
                if !host.unavailableHooks.isEmpty {
                    Text(verbatim: unavailableHooksSummary).crestFormFootnote()
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Crest \(BrowserAboutBuildInformation.current.version)")
                .font(.body.weight(.medium))
            if let manifest = host.manifest {
                Text(
                    verbatim:
                        "Plugin host \(manifest.hostVersion), hook catalog \(manifest.hookCatalogVersion), built for Crest \(manifest.crestVersion)"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Text("This build was made without the plugin system.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableHooksSummary: String {
        host.unavailableHooks.map { hook in
            "\(hook.id) did not apply to this Crest" + (hook.reason.map { ": \($0)" } ?? ".")
        }.joined(separator: "\n")
    }
}

/// One plugin's row: its switch, what it is, and where it stands.
struct BrowserPluginSettingsRow: View {
    let record: CrestPluginHost.Record
    let setEnabled: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CrestSpacing.extraExtraSmall) {
            Toggle(isOn: Binding(get: { record.isEnabled }, set: setEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: record.manifest.name)
                    Text(verbatim: "\(record.manifest.version) · \(record.manifest.summary)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!record.state.offersToggle)
            .accessibilityIdentifier("plugin-\(record.id)-toggle")

            Label {
                Text(verbatim: standing)
            } icon: {
                Image(systemName: record.state.symbol)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var standing: String {
        var text = record.state.title
        if record.manifest.requiresRelaunch, record.state == .active {
            text += ", changes after relaunch"
        }
        if let reason = record.state.reason {
            text += ": \(reason)"
        }
        return text
    }
}
