import SwiftUI

/// The plugin's rows in Settings → Crest Plugins: whether copies follow their
/// home tab, and every shared tab with the Spaces it is shared into.
struct SharedPinnedTabsSettingsRows: View {
    let service: SharedPinnedTabsService

    var body: some View {
        Toggle(
            "Copies follow the home tab's address, name and icon",
            isOn: Binding(get: { service.mirrorsFollowHome }, set: { service.mirrorsFollowHome = $0 }))

        if service.shares.isEmpty {
            Text("No pinned tab is shared. Right-click a pinned tab and choose Share in Spaces.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(service.shares) { share in
                SharedPinnedTabRow(service: service, share: share)
            }
        }
    }
}

/// One shared tab: its name and home, where it is shared, and the way to stop.
private struct SharedPinnedTabRow: View {
    let service: SharedPinnedTabsService
    let share: SharedPinnedTabsService.Share

    var body: some View {
        let browser = service.browser
        let homeSpace = browser.spaceModel(share.homeSpaceID)
        let homeTab = homeSpace?.tabs.model(share.homeTabID)
        let members = share.mirrors.compactMap { browser.spaceModel($0.spaceID)?.settings.name }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: homeTab?.shownTitle ?? homeTab?.savedURL ?? "Pinned tab")
                Text(
                    verbatim:
                        "From \(homeSpace?.settings.name ?? "a deleted Space") · \(members.joined(separator: ", "))"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Stop Sharing") {
                service.stopSharing(homeTabID: share.homeTabID)
            }
        }
    }
}

/// On a Space's settings page: the pinned tabs this Space shares out, and the
/// copies it holds from other Spaces.
struct SharedPinnedTabsSpaceSection: View {
    let service: SharedPinnedTabsService
    let space: SpaceModel

    var body: some View {
        let browser = service.browser
        let sharedOut = service.shares.filter { $0.homeSpaceID == space.id }
        let copies = service.shares.filter { $0.mirror(in: space.id) != nil }
        if !sharedOut.isEmpty || !copies.isEmpty {
            Section {
                ForEach(sharedOut) { share in
                    let names = share.mirrors.compactMap { browser.spaceModel($0.spaceID)?.settings.name }
                    row(
                        title: space.tabs.model(share.homeTabID)?.shownTitle ?? "Pinned tab",
                        detail: "Shared into \(names.joined(separator: ", "))")
                }
                ForEach(copies) { share in
                    let homeSpace = browser.spaceModel(share.homeSpaceID)
                    row(
                        title: homeSpace?.tabs.model(share.homeTabID)?.shownTitle ?? "Pinned tab",
                        detail: "Signed in as \(homeSpace?.settings.name ?? "its home Space")")
                }
            } header: {
                Text("Shared pinned tabs")
            }
        }
    }

    private func row(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
            Text(verbatim: detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
