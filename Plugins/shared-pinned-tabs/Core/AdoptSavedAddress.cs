using CrestCore.Application;

namespace CrestCore.Contracts;

/// Gives a saved or pinned tab the address `Url` as the one it belongs to,
/// taken as it is from another tab that already resolved it, so a copy of a
/// pinned tab in another Space follows the address of the tab it copies. The
/// tab keeps showing its page; returning it then takes it to the new address.
/// Refused with `NoSavedAddress` for a tab that belongs nowhere.
public sealed record AdoptSavedAddress(Guid WorkspaceId, Guid SpaceId, Guid TabId, string Url) : SessionIntent(WorkspaceId) {
    #region Actions - Session

    internal override SessionEdit? Edit(NativeSessionAuthority workspace, SessionTurn turn) =>
        workspace.Organizing(turn.Basis, SpaceId, SyncStaging.Edit, edited => edited.Tab(TabId).AdoptSavedAddress(Url));

    #endregion
}
