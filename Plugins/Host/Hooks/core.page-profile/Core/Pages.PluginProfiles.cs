using CrestCore.Contracts;

namespace CrestCore.Application;

/// The core.page-profile hook's part of the pages: the profile a plugin
/// assigned a tab, which the tab's pages run in instead of its Space's. Memory
/// only: a plugin that assigns profiles stores the assignments itself and
/// sends them again when it starts.
internal sealed partial class Pages {
    #region Variables

    /// The profile each assigned tab's pages run in, by tab.
    private readonly Dictionary<Guid, Guid> assignedProfiles = [];

    #endregion

    #region Actions - Profiles

    /// The profile a page of `tabId` in `space` runs in: the one a plugin
    /// assigned the tab, while a Space of `workspace` still holds that profile,
    /// and otherwise the Space's own. A transient request's page always runs in
    /// its Space's.
    internal Guid ProfileFor(NativeSessionAuthority workspace, SpaceState space, Guid? tabId) =>
        tabId is { } id && assignedProfiles.TryGetValue(id, out var assigned) && workspace.Current.Spaces.Any(held => held.ProfileId == assigned)
            ? assigned
            : space.ProfileId;

    /// Whether a page the engine made in `profileId` may join `space`: the
    /// Space's own profile always, and the profile the opener's tab was
    /// assigned when the page was opened by a page of that Space, so a sign-in
    /// window a shared tab opens keeps the session it was opened from.
    internal bool Hosts(NativeSessionAuthority workspace, SpaceState space, Guid profileId, Page? source) =>
        space.ProfileId == profileId
        || source is { TabId: { } tab } && source.SpaceId == space.Id && ProfileFor(workspace, space, tab) == profileId;

    /// Gives `tabId`'s next pages `profileId`, or takes an assignment back for
    /// null. A page the tab has open keeps the profile it opened in; the
    /// caller puts it away so the next one opens in the assigned profile.
    internal void AssignProfile(Guid tabId, Guid? profileId) {
        if (profileId is { } assigned) assignedProfiles[tabId] = assigned;
        else assignedProfiles.Remove(tabId);
    }

    /// The profile assigned to `tabId`, or null for none.
    internal Guid? AssignedProfile(Guid tabId) => assignedProfiles.TryGetValue(tabId, out var assigned) ? assigned : null;

    #endregion
}
