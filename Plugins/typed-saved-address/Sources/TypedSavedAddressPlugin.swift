import SwiftUI

/// Adds Edit URL… to a saved or pinned tab's Edit Tab menu. The prompt asks
/// for the address the tab belongs to and stores what was typed, read by the
/// Space's address rules; until then the saved address could only be
/// replaced with the page the tab was showing, so a link a site redirects at
/// once could never become the saved one. Saving sends the tab there the way
/// returning to a saved address does.
@MainActor
final class TypedSavedAddressPlugin: CrestPlugin {
    // MARK: - Static Variables

    static let id = "typed-saved-address"

    // MARK: - Initializers

    init() {}

    // MARK: - Actions - Lifecycle

    func activate(_ context: CrestPluginContext) throws {
        context.contribute(
            CrestPluginTabAction(
                id: "edit-url", title: "Edit URL…", systemImage: "link",
                isAvailable: { $0.supportsSavedLocationEditing },
                perform: Self.askForAddress),
            at: CrestPluginTabAction.hook)
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
