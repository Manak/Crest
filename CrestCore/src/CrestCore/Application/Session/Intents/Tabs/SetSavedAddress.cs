using CrestCore.Application;
using CrestCore.Domain;

namespace CrestCore.Contracts;

/// Gives a saved or pinned tab the address `Input` names, resolved by its
/// Space's address rules as `Navigate` resolves one, as the one it belongs
/// to. The tab keeps showing its page, which returning it then takes to the
/// new address. Refused with `NoSavedAddress` for a tab that belongs nowhere,
/// and with `UnsupportedAddress` when `Input` names nothing a page can load,
/// as blank input does.
public sealed record SetSavedAddress(Guid WorkspaceId, Guid SpaceId, Guid TabId, string Input) : SessionIntent(WorkspaceId) {
    #region Actions - Session

    internal override SessionEdit? Edit(NativeSessionAuthority workspace, SessionTurn turn) {
        var space = workspace.Editable(turn.Basis, SpaceId);
        var url = AddressResolution.Loading(Input, workspace.SearchCatalog.For(space.Settings.BrowsingPreferences, workspace.Kind.IsPrivate),
            turn.Pages?.OpensInternalPages ?? false);
        return workspace.Organizing(turn.Basis, SpaceId, SyncStaging.Edit, edited => edited.Tab(TabId).SetSavedAddress(url));
    }

    #endregion
}
