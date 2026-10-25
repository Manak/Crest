import SwiftUI

/// Settings → Crest Plugins: the build the plugins were made with, then one
/// section per plugin with its switch, where it stands, and the rows the
/// plugin shows while it is on. The hooks this Crest could not take close the
/// page.
struct BrowserPluginsSettingsPane: View {
    @Environment(CrestPluginHost.self) private var host

    var body: some View {
        BrowserSettingsPane(.plugins) {
            Section {
                summary
            }

            if host.records.isEmpty {
                Section {
                    Text("This build carries no plugins.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(host.records) { record in
                    BrowserPluginSettingsSection(record: record, storage: host.storage(for: record.id)) { isEnabled in
                        host.setEnabled(isEnabled, for: record.id)
                    }
                }
            }

            if !host.unavailableHooks.isEmpty {
                Section {
                    ForEach(host.unavailableHooks) { hook in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: hook.id)
                            Text(verbatim: hook.reason ?? "The patch did not apply to this Crest.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text("Hooks this Crest could not take")
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
}

/// One plugin's section: its switch and summary, its standing, and the rows
/// the plugin contributes while it is on.
struct BrowserPluginSettingsSection: View {
    let record: CrestPluginHost.Record
    let storage: CrestPluginStorage
    let setEnabled: (Bool) -> Void

    @Environment(CrestPluginHost.self) private var host

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { record.isEnabled }, set: setEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: record.manifest.summary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label {
                        Text(verbatim: standing)
                    } icon: {
                        Image(systemName: record.state.symbol)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!record.state.offersToggle)
            .accessibilityIdentifier("plugin-\(record.id)-toggle")

            if record.state == .active {
                ForEach(host.contributions.contributions(at: CrestPluginSettingsPanel.hook, from: record.id)) {
                    panel in
                    panel.make()
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: record.manifest.name)
                Spacer()
                Text(verbatim: record.manifest.version)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !storage.isEmpty {
                Text(verbatim: storageSummary).crestFormFootnote()
            }
        }
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

    private var storageSummary: String {
        let values = storage.keys.count
        let spaces = storage.spaceIDs.count
        var parts: [String] = []
        if values > 0 { parts.append(values == 1 ? "1 stored value" : "\(values) stored values") }
        if spaces > 0 { parts.append(spaces == 1 ? "data for 1 Space" : "data for \(spaces) Spaces") }
        let persistence = storage.isPersistent ? "kept between launches" : "kept for this launch only"
        return parts.joined(separator: ", ") + ", " + persistence + "."
    }
}
