import SwiftUI

/// An action a plugin adds to a tab's Edit Tab menu, offered where the tab
/// qualifies and run with what the menu knows about the tab.
struct CrestPluginTabAction: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginTabAction>(id: "tabs.edit-actions", version: 1)

    // MARK: - Variables

    let id: String
    let title: String
    let systemImage: String
    let isAvailable: @MainActor (TabStateModel) -> Bool
    let perform: @MainActor (CrestPluginTabActionContext) -> Void
}

/// What a tab action works with: the tab and where it lives, the window's
/// store, the surface's way of returning the tab to its saved address, and a
/// prompt the action may ask through.
struct CrestPluginTabActionContext {
    let tab: TabStateModel
    let assignment: BrowserTabRuntimeAssignment
    let browser: BrowserStore
    let restoreSavedLocation: (() -> Void)?
    let prompt: CrestPluginTextPromptPresenter
}

/// A one-field question a plugin asks on a tab's surface: a sidebar row or a
/// pinned tile, which has no room to edit in place.
struct CrestPluginTextPromptRequest: Identifiable {
    // MARK: - Types

    /// What the field takes, which chooses the keyboard on iPhone and iPad.
    struct Keyboard: Equatable, Sendable {
        static let text = Keyboard(name: "text")
        static let url = Keyboard(name: "url")

        let name: String
    }

    // MARK: - Variables

    let id = UUID()
    let assignment: BrowserTabRuntimeAssignment
    let title: String
    let fieldLabel: String
    let initialText: String
    let confirmTitle: String
    var keyboard = Keyboard.text
    let commit: @MainActor (String) -> Void
}

/// Hands a prompt request to the surface that shows it. A surface with no
/// prompt of its own, or no host, presents nothing.
struct CrestPluginTextPromptPresenter {
    static let unavailable = CrestPluginTextPromptPresenter { _ in }

    let present: @MainActor (CrestPluginTextPromptRequest) -> Void
}

extension EnvironmentValues {
    /// Where a tab action's prompt shows: the row or tile under the menu.
    @Entry var crestPluginTabPrompt = CrestPluginTextPromptPresenter.unavailable
}

/// Shows the prompt a plugin requested on a tab's surface as an alert with
/// one field; Save commits what was typed and Cancel leaves the tab alone.
struct CrestPluginTextPromptModifier: ViewModifier {
    @Binding var request: CrestPluginTextPromptRequest?

    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, _ in
                draft = request?.initialText ?? ""
            }
            .alert(
                request?.title ?? "",
                isPresented: Binding(
                    get: { request != nil },
                    set: { isPresented in
                        if !isPresented { request = nil }
                    }),
                presenting: request
            ) { request in
                field(for: request)
                    .accessibilityIdentifier("plugin-prompt-field")
                Button(request.confirmTitle) {
                    request.commit(draft)
                }
                .accessibilityIdentifier("plugin-prompt-confirm")
                Button("Cancel", role: .cancel) {}
            }
    }

    @ViewBuilder
    private func field(for request: CrestPluginTextPromptRequest) -> some View {
        #if os(iOS)
            TextField(request.fieldLabel, text: $draft)
                .keyboardType(request.keyboard == .url ? .URL : .default)
                .textInputAutocapitalization(request.keyboard == .url ? .never : .sentences)
                .autocorrectionDisabled(request.keyboard == .url)
        #else
            TextField(request.fieldLabel, text: $draft)
                .autocorrectionDisabled(request.keyboard == .url)
        #endif
    }
}

extension View {
    /// Presents the plugin prompt `request` holds while it is set.
    func crestPluginTextPrompt(_ request: Binding<CrestPluginTextPromptRequest?>) -> some View {
        modifier(CrestPluginTextPromptModifier(request: request))
    }
}
