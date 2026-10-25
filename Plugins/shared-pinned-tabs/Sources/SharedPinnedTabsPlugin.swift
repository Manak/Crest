import SwiftUI

/// Shares a pinned tab into other Spaces. Each copy is a real pinned tab of
/// its Space, so it drags, renames and shows like any other, but its pages
/// run in the home Space's engine profile: the person is signed in there as
/// they are at home, and Spaces otherwise keep their cookies apart. The
/// copies follow the home tab's address, name and emoji icon, and go when the
/// home tab is unpinned or its Space deleted.
@MainActor
final class SharedPinnedTabsPlugin: CrestPlugin {
    // MARK: - Static Variables

    static let id = "shared-pinned-tabs"

    // MARK: - Variables

    private var service: SharedPinnedTabsService?

    // MARK: - Initializers

    init() {}

    // MARK: - Actions - Lifecycle

    func activate(_ context: CrestPluginContext) throws {
        let service = SharedPinnedTabsService(browser: context.browser, storage: context.storage)
        self.service = service
        service.start()

        context.contribute(
            CrestPluginTabMenuItems(
                id: "share-in-spaces",
                isAvailable: { $0.placement == .pinned },
                content: { tabContext in
                    CrestPluginView(SharedPinnedTabsMenuItems(service: service, context: tabContext))
                }
            ),
            at: CrestPluginTabMenuItems.hook)

        context.contribute(
            CrestPluginSpaceObserver(
                id: Self.id,
                spacesRemoved: { service.spacesRemoved($0) },
                sessionChanged: { service.reconcile() }),
            at: CrestPluginSpaceObserver.hook)

        context.contribute(
            CrestPluginSettingsPanel(id: Self.id) { CrestPluginView(SharedPinnedTabsSettingsRows(service: service)) },
            at: CrestPluginSettingsPanel.hook)

        context.contribute(
            CrestPluginSpaceSettingsSection(id: Self.id) { spaceContext in
                CrestPluginView(SharedPinnedTabsSpaceSection(service: service, space: spaceContext.space))
            },
            at: CrestPluginSpaceSettingsSection.hook)
    }

    func deactivate() {
        service?.stop()
        service = nil
    }
}
