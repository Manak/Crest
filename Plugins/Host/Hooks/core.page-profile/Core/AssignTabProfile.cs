using CrestCore.Application;

namespace CrestCore.Contracts;

/// Makes `ProfileId` the profile the pages of `TabId` run in from now on,
/// in place of its Space's, so the tab shares that profile's cookies and
/// storage; null takes the assignment back. The profile must be one a Space of
/// `WorkspaceId` holds, or the intent is refused with `ProfileNotHeld`. A page
/// the tab has open is left in the profile it opened in; put it away to
/// reopen it in the assigned one. Assignments are kept for this run only.
public sealed record AssignTabProfile(Guid WorkspaceId, Guid TabId, Guid? ProfileId) : PageIntent {
    #region Actions - Pages

    internal override void Apply(Pages pages, PageTurn turn) {
        var workspace = pages.Device.Workspace(WorkspaceId);
        if (ProfileId is { } profile && !workspace.Current.Spaces.Any(space => space.ProfileId == profile))
            throw new Rejected(new ProfileNotHeld(profile));
        pages.AssignProfile(TabId, ProfileId);
    }

    #endregion
}

/// No Space of the workspace holds the profile, so no tab can be given it.
public sealed record ProfileNotHeld(Guid ProfileId) : Rejection;
