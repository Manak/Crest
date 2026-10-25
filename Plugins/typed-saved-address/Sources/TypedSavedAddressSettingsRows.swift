import SwiftUI

/// The plugin's row in Settings → Crest Plugins: whether a pinned tab without
/// a page goes back to its saved address.
struct TypedSavedAddressSettingsRows: View {
    let service: PinnedTabSavedAddressService

    var body: some View {
        Toggle(
            "Pinned tabs reopen at their saved URL",
            isOn: Binding(get: { service.reopensAtSavedAddress }, set: { service.reopensAtSavedAddress = $0 }))
    }
}
