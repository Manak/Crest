import SwiftUI

/// Adds Edit URL… to a saved or pinned tab's Edit Tab menu. The prompt asks
/// for the address the tab belongs to and stores what was typed, read by the
/// Space's address rules; until then the saved address could only be
/// replaced with the page the tab was showing, so a link a site redirects at
/// once could never become the saved one. Saving sends the tab there the way
/// returning to a saved address does.
///
/// A pinned tab also keeps that address the way a pinned link would: while
/// it has no page, at launch or after its page was unloaded, put away or
/// closed, it returns to its saved address, so it opens there next rather
/// than at the page it showed last.
@MainActor
final class TypedSavedAddressPlugin: CrestPlugin {
    // MARK: - Static Variables

    static let id = "typed-saved-address"

    // MARK: - Variables

    private var service: PinnedTabSavedAddressService?

    // MARK: - Initializers

    init() {}

    // MARK: - Actions - Lifecycle

    func activate(_ context: CrestPluginContext) throws {
        let service = PinnedTabSavedAddressService(browser: context.browser, storage: context.storage)
        self.service = service
        // Plugins start before any page opens, so every pinned tab is fresh.
        service.returnFreshPinnedTabs()

        context.contribute(
            CrestPluginTabAction(
                id: "edit-url", title: "Edit URL…", systemImage: "link",
                isAvailable: { $0.supportsSavedLocationEditing },
                perform: Self.askForAddress),
            at: CrestPluginTabAction.hook)

        context.contribute(
            CrestPluginSpaceObserver(
                id: Self.id,
                sessionChanged: { service.returnFreshPinnedTabs() },
                pagesChanged: { service.returnFreshPinnedTabs() }),
            at: CrestPluginSpaceObserver.hook)

        context.contribute(
            CrestPluginSettingsPanel(id: Self.id) { CrestPluginView(TypedSavedAddressSettingsRows(service: service)) },
            at: CrestPluginSettingsPanel.hook)
    }

    func deactivate() {
        service = nil
    }

    // MARK: - Actions - Editing

    private static func askForAddress(_ context: CrestPluginTabActionContext) {
        guard let address = context.tab.savedURL ?? context.tab.url else { return }
        let assignment = context.assignment
        let browser = context.browser
        let restore = context.restoreSavedLocation
        context.prompt.present(
            CrestPluginTextPromptRequest(
                assignment: assignment, title: "Edit URL", fieldLabel: "URL", initialText: address,
                confirmTitle: "Save", keyboard: .url
            ) { input in
                guard browser.setTabSavedAddress(input, for: assignment.tabID, in: assignment.spaceID) else { return }
                restore?()
            })
    }
}
