namespace CrestCore.Domain;

/// The shared-pinned-tabs plugin's part of a tab: a saved address taken from
/// the tab this one copies.
public sealed partial class BrowserTab {
    #region Actions - Shared pins

    /// Makes `url`, already resolved by the tab it is copied from, the address
    /// the tab belongs to, leaving the page it shows where it is. Refused with
    /// `NoSavedAddress` for a tab that belongs nowhere.
    public void AdoptSavedAddress(string url) {
        _ = RequiredSavedAddress();
        State = State with { SavedUrl = url };
    }

    #endregion
}
