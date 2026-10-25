using CrestCore.Application;
using CrestCore.Contracts;

using Xunit;

namespace CrestCore.Tests;

/// The core.page-profile hook the shared-pinned-tabs plugin runs on: a tab
/// given another Space's profile opens its pages there, the windows those
/// pages open stay in that profile, an assignment to a profile no Space holds
/// is refused, and one whose Space has gone falls back to the tab's own Space.
public sealed partial class BrowserContractsTests {
    [Fact]
    public void ATabAssignedAnotherSpacesProfileOpensItsPagesAndTheirWindowsThere() {
        var session = TwoSpaceSession();
        var (home, member) = (session["spaces"]![0]!, session["spaces"]![1]!);
        var (homeProfile, memberProfile) = (ProfileId(home), ProfileId(member));
        var (app, engine, binding, workspace, window) = PageHost(session);
        using var disposal = app;
        var copy = TabId(member, 0);

        // Without an assignment the copy's page runs in its own Space's profile.
        var plain = Guid.NewGuid();
        app.Send(new OpenPage(plain, workspace, SpaceId(member), copy, window));
        Assert.Equal(memberProfile, binding.Commands.OfType<CreatePage>().Single(command => command.PageId == plain).ProfileId);
        app.Send(new ReleasePage(plain, KeepsState: false));

        // Assigned the home profile, the next page opens there.
        app.Send(new AssignTabProfile(workspace, copy, homeProfile));
        var shared = Guid.NewGuid();
        app.Send(new OpenPage(shared, workspace, SpaceId(member), copy, window));
        Assert.Equal(homeProfile, binding.Commands.OfType<CreatePage>().Single(command => command.PageId == shared).ProfileId);
        app.Report(engine, new PageCreated(shared));
        app.Drain();

        // A sign-in window the shared page opens in the home profile joins its
        // Space, in that profile.
        var offer = Guid.NewGuid();
        app.Report(engine, new PageOffered(offer, homeProfile, shared, null, SpaceId(member), "https://login.example/", true));
        var adopted = Assert.IsType<AdoptOfferedPage>(binding.Commands[^1]);
        Assert.Equal((offer, homeProfile), (adopted.OfferId, adopted.ProfileId));
        Assert.Single(app.Drain().OfType<OfferedWindowAdopted>());

        // A page another Space's tab did not open stays refused.
        var stray = Guid.NewGuid();
        app.Report(engine, new PageOffered(stray, homeProfile, null, window, SpaceId(member), "https://stray.example/", true));
        Assert.Equal(new RejectOfferedPage(stray), binding.Commands[^1]);

        // No Space holds an unknown profile, so no tab can be given it.
        Assert.IsType<ProfileNotHeld>(Refusal(app, new AssignTabProfile(workspace, copy, Guid.NewGuid())));

        // Taken back, the tab's pages open in its own Space's profile again.
        app.Send(new ReleasePage(shared, KeepsState: false));
        app.Send(new AssignTabProfile(workspace, copy, null));
        var own = Guid.NewGuid();
        app.Send(new OpenPage(own, workspace, SpaceId(member), copy, window));
        Assert.Equal(memberProfile, binding.Commands.OfType<CreatePage>().Single(command => command.PageId == own).ProfileId);
    }
}
