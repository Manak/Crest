import SwiftUI

/// Asks for the address a saved or pinned tab belongs to.
///
/// Neither a sidebar row nor a pinned tile has room to edit a URL in place
/// the way a row edits its name, so the address is asked for instead. Save
/// commits what was typed, which the Space's address rules read as the
/// command palette reads an address; Cancel leaves the tab as it was.
struct BrowserTabSavedAddressPrompt: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var draft: String
    let commit: () -> Void

    func body(content: Content) -> some View {
        content.alert("Edit URL", isPresented: $isPresented) {
            addressField
                .accessibilityIdentifier("tab-saved-address-field")

            Button("Save", action: commit)
                .accessibilityIdentifier("confirm-tab-saved-address")

            Button("Cancel", role: .cancel) {}
        }
    }

    /// A field that takes a web address: no autocorrection, and on iPhone and
    /// iPad the URL keyboard without capitals.
    private var addressField: some View {
        #if os(iOS)
            TextField("URL", text: $draft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        #else
            TextField("URL", text: $draft)
                .autocorrectionDisabled()
        #endif
    }
}

extension View {
    /// Asks for the address a saved or pinned tab belongs to while
    /// `isPresented`, editing `draft`, and runs `commit` when it is saved.
    func browserTabSavedAddressPrompt(
        isPresented: Binding<Bool>,
        draft: Binding<String>,
        commit: @escaping () -> Void
    ) -> some View {
        modifier(BrowserTabSavedAddressPrompt(isPresented: isPresented, draft: draft, commit: commit))
    }
}
