import SwiftUI

/// What a pinned tab's menu offers: a home tab lists the Spaces to share it
/// into, each ticked while a copy is there; a copy says where it is from and
/// offers to stop.
struct SharedPinnedTabsMenuItems: View {
    let service: SharedPinnedTabsService
    let context: CrestPluginTabActionContext

    var body: some View {
        if let share = service.share(ofMirror: context.tab.id) {
            mirrorItems(share)
        } else {
            homeItems
        }
    }

    private var homeItems: some View {
        Menu("Share in Spaces", systemImage: "square.on.square") {
            let spaces = service.candidateSpaces(forHomeIn: context.assignment.spaceID)
            if spaces.isEmpty {
                Text("No other Spaces")
            }
            ForEach(spaces) { space in
                Toggle(
                    isOn: Binding(
                        get: { service.isShared(context.tab.id, in: space.id) },
                        set: { isOn in
                            guard isCurrent else { return }
                            service.setShared(isOn, home: context.assignment, in: space.id)
                        })
                ) {
                    Label {
                        Text(verbatim: space.settings.name)
                    } icon: {
                        Image(systemName: space.settings.symbol)
                    }
                }
            }
            if service.share(ofHome: context.tab.id) != nil {
                Divider()
                Button("Stop Sharing Everywhere", systemImage: "square.slash") {
                    guard isCurrent else { return }
                    service.stopSharing(homeTabID: context.tab.id)
                }
            }
        }
    }

    @ViewBuilder
    private func mirrorItems(_ share: SharedPinnedTabsService.Share) -> some View {
        let homeSpace = context.browser.spaceModel(share.homeSpaceID)
        Button {
            guard let homeSpace else { return }
            context.browser.selectSpace(homeSpace.id)
            context.browser.activateSessionTab(share.homeTabID, in: homeSpace.id)
        } label: {
            Label {
                Text(verbatim: "Shared from \(homeSpace?.settings.name ?? "another Space")")
            } icon: {
                Image(systemName: homeSpace?.settings.symbol ?? "square.on.square")
            }
        }
        .disabled(homeSpace == nil)

        Button("Stop Sharing Here", systemImage: "square.slash") {
            guard isCurrent else { return }
            service.setShared(
                false,
                home: BrowserTabRuntimeAssignment(
                    tabID: share.homeTabID, spaceID: share.homeSpaceID,
                    profileID: homeSpace?.profileID ?? context.assignment.profileID),
                in: context.assignment.spaceID)
        }
    }

    /// Whether the tab the menu was drawn for is still a pinned tab of a Space
    /// the window may act on.
    private var isCurrent: Bool {
        guard let space = context.browser.spaceModel(context.assignment.spaceID), !context.browser.isDeleting(space.id),
            let tab = space.tabs.model(context.tab.id)
        else { return false }
        return tab.placement == .pinned
    }
}
