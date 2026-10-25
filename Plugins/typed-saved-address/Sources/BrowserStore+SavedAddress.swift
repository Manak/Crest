import Foundation

extension BrowserStore {
    /// Makes the address `input` names by the Space's rules the one a saved or
    /// pinned tab belongs to, and answers whether the core accepted it. The
    /// plugin's own intent; the core resolves the input as it does an address
    /// typed into the palette.
    @discardableResult
    func setTabSavedAddress(_ input: String, for tabID: UUID, in spaceID: UUID) -> Bool {
        family.perform(
            SetSavedAddress(workspaceID: family.workspaceID, spaceID: spaceID, tabID: tabID, input: input),
            from: self) != nil
    }
}
