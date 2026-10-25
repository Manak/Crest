using CrestCore.Application;
using CrestCore.Contracts;

using Xunit;

namespace CrestCore.Tests;

/// The typed-saved-address plugin's intent: a typed address, read by the
/// Space's rules, becomes the one a saved tab belongs to.
public sealed partial class BrowserContractsTests {
    [Fact]
    public void ATypedAddressBecomesTheOneASavedTabBelongsToAndAnOpenTabRefusesIt() {
        var fixture = SavedSession(); var session = fixture.Document["session"]!;
        using var device = new TestDevice(session);
        var core = device.Authority;
        TabState Tab() => core.Current.Spaces[0].Tabs[0];
        Assert.True(Tab().IsAwayFromSavedAddress);

        // The page stays where it is until the tab returns.
        device.Send(new SetSavedAddress(device.Workspace, fixture.Space, fixture.Tab, "example.com/inbox?user=a@b.c"));
        Assert.Equal(("https://example.com/inbox?user=a@b.c", "https://example.com/article#one", true),
            (Tab().SavedUrl, Tab().Url, Tab().IsAwayFromSavedAddress));
        device.Send(new ReturnToSavedAddress(device.Workspace, fixture.Space, fixture.Tab));
        Assert.Equal(("https://example.com/inbox?user=a@b.c", false), (Tab().Url, Tab().IsAwayFromSavedAddress));

        // Blank input names nothing a page can load.
        var set = core.Current;
        Assert.IsType<UnsupportedAddress>(Assert.Throws<Rejected>(() =>
            device.Send(new SetSavedAddress(device.Workspace, fixture.Space, fixture.Tab, " "))).Rejection);
        Assert.Same(set, core.Current);

        // An open tab belongs nowhere.
        var open = session.DeepClone();
        var tab = open["spaces"]![0]!["tabs"]![0]!;
        tab["placement"] = "current"; tab["savedURL"] = null; tab["folderID"] = null;
        using var browsing = new TestDevice(open);
        var before = browsing.Authority.Current;
        Assert.IsType<NoSavedAddress>(Assert.Throws<Rejected>(() =>
            browsing.Send(new SetSavedAddress(browsing.Workspace, fixture.Space, fixture.Tab, "https://example.com/"))).Rejection);
        Assert.Same(before, browsing.Authority.Current);
    }
}
