import Foundation

extension BrowserStore {
    /// Makes `profileID` the engine profile the pages of `tabID` run in, or
    /// takes the assignment back for nil, and answers whether the core
    /// accepted it. The host's `core.page-profile` intent; the core refuses a
    /// profile no Space holds.
    @discardableResult
    func assignTabProfile(_ profileID: UUID?, to tabID: UUID) -> Bool {
        (try? core.send(AssignTabProfile(workspaceID: family.workspaceID, tabID: tabID, profileID: profileID))) != nil
    }

    /// Makes `url` the address a saved or pinned tab belongs to, as another tab
    /// already resolved it, and answers whether the core accepted it. The
    /// plugin's own intent.
    @discardableResult
    func adoptTabSavedAddress(_ url: String, for tabID: UUID, in spaceID: UUID) -> Bool {
        family.perform(
            AdoptSavedAddress(workspaceID: family.workspaceID, spaceID: spaceID, tabID: tabID, url: url), from: self)
            != nil
    }
}
