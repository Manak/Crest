namespace CrestCore.Domain;

/// The typed-saved-address plugin's part of a tab: a saved address set from
/// typed input rather than from the page the tab shows.
public sealed partial class BrowserTab {
    #region Actions - Saved address

    /// Makes `url` the address the tab belongs to, leaving the page it shows
    /// where it is. Refused with `NoSavedAddress` for a tab that belongs
    /// nowhere.
    public void SetSavedAddress(string url) {
        _ = RequiredSavedAddress();
        State = State with { SavedUrl = url };
    }

    #endregion
}
