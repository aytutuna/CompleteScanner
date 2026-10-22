using System.Net;
using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Trusted networks, the peers answered, rate limits, the firewall's verdict and the phone checks
// (Windows only, like WindowsSystemStatusTests: no Swift twin).

internal static class Networks
{
    public static CompanionNetworkInterface Adapter(int index, string address, int prefix, string? adapterId = null) =>
        new(index, adapterId ?? $"{{0000000{index}-0000-0000-0000-000000000000}}", [new LocalSubnet(IPAddress.Parse(address), prefix)]);

    public static CompanionNetwork Home(CompanionNetworkCategory category = CompanionNetworkCategory.Private) =>
        new("{11111111-1111-1111-1111-111111111111}", "Home Wi-Fi", category, [Adapter(7, "192.168.1.20", 24)]);

    public static CompanionNetwork College(CompanionNetworkCategory category = CompanionNetworkCategory.Public) =>
        new("{22222222-2222-2222-2222-222222222222}", "eduroam", category, [Adapter(9, "141.20.5.17", 16)]);
}

public sealed class CompanionNetworkTests : IDisposable
{
    private static readonly DateTimeOffset Now = new(2026, 10, 20, 8, 30, 0, TimeSpan.Zero);
    private readonly string _directory;

    public CompanionNetworkTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "CompleteScannerTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private static bool None(string id) => false;

    [Fact]
    public void Trust_PrivateOrApprovedOnly()
    {
        Assert.Equal(NetworkTrust.Private, TrustedNetworkPolicy.Trust(Networks.Home(), None));
        Assert.Equal(NetworkTrust.NotTrusted, TrustedNetworkPolicy.Trust(Networks.College(), None));
        Assert.Equal(NetworkTrust.NotTrusted, TrustedNetworkPolicy.Trust(Networks.College(CompanionNetworkCategory.Domain), None));
        Assert.Equal(NetworkTrust.Approved, TrustedNetworkPolicy.Trust(Networks.College(), id => id == Networks.College().Id));
        Assert.Equal(NetworkTrust.NotTrusted, TrustedNetworkPolicy.Trust(Networks.College() with { Id = "" }, _ => true));
    }

    [Fact]
    public void ListenAddresses_AreTheTrustedNetworksOnly()
    {
        var both = new[] { Networks.College(), Networks.Home() };
        Assert.Equal(["192.168.1.20"], TrustedNetworkPolicy.ListenAddresses(both, None).Select(a => a.Address.ToString()));
        Assert.Equal(["141.20.5.17", "192.168.1.20"],
                     TrustedNetworkPolicy.ListenAddresses(both, _ => true).Select(a => a.Address.ToString()));
        Assert.Empty(TrustedNetworkPolicy.ListenAddresses([Networks.College()], None));
        // An adapter that also carries an untrusted network is never listened on.
        var shared = Networks.Home() with { Interfaces = [Networks.Adapter(9, "192.168.1.20", 24, Networks.College().Interfaces[0].AdapterId)] };
        Assert.Empty(TrustedNetworkPolicy.ListenAddresses([shared, Networks.College()], None));
        // IPv4 first, each address once.
        var dual = Networks.Home() with
        {
            Interfaces = [new CompanionNetworkInterface(7, "a", [new LocalSubnet(IPAddress.Parse("fd00::5"), 64),
                                                                 new LocalSubnet(IPAddress.Parse("192.168.1.20"), 24)]),
                          new CompanionNetworkInterface(8, "b", [new LocalSubnet(IPAddress.Parse("192.168.1.20"), 24)])],
        };
        Assert.Equal(["192.168.1.20", "fd00::5"], TrustedNetworkPolicy.ListenAddresses([dual], None).Select(a => a.Address.ToString()));
    }

    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("10.1.2.3", true)]
    [InlineData("172.16.0.1", true)]
    [InlineData("172.31.255.255", true)]
    [InlineData("172.32.0.1", false)]
    [InlineData("192.168.200.1", true)]
    [InlineData("169.254.10.10", true)]
    [InlineData("100.64.0.1", true)]
    [InlineData("100.128.0.1", false)]
    [InlineData("8.8.8.8", false)]
    [InlineData("::1", true)]
    [InlineData("fe80::1", true)]
    [InlineData("fd12:3456::1", true)]
    [InlineData("2001:db8::1", false)]
    [InlineData("::ffff:192.168.1.5", true)]
    public void IsLocalAddress_CoversPrivateRanges(string address, bool local) =>
        Assert.Equal(local, TrustedNetworkPolicy.IsLocalAddress(IPAddress.Parse(address)));

    [Fact]
    public void IsAllowedPeer_AlsoTakesTheListenedSubnet()
    {
        var listening = new[] { new LocalSubnet(IPAddress.Parse("141.20.5.17"), 16) };
        Assert.True(TrustedNetworkPolicy.IsAllowedPeer(IPAddress.Parse("141.20.200.9"), listening));
        Assert.True(TrustedNetworkPolicy.IsAllowedPeer(IPAddress.Parse("::ffff:141.20.200.9"), listening));
        Assert.False(TrustedNetworkPolicy.IsAllowedPeer(IPAddress.Parse("141.21.0.1"), listening));
        Assert.True(TrustedNetworkPolicy.IsAllowedPeer(IPAddress.Parse("192.168.1.5"), listening));
        Assert.False(TrustedNetworkPolicy.IsAllowedPeer(IPAddress.Parse("8.8.8.8"), listening));
    }

    [Fact]
    public void LocalSubnet_ComparesThePrefixOnly()
    {
        var subnet = new LocalSubnet(IPAddress.Parse("10.0.0.130"), 25);
        Assert.True(subnet.Contains(IPAddress.Parse("10.0.0.255")));
        Assert.False(subnet.Contains(IPAddress.Parse("10.0.0.127")));
        Assert.False(subnet.Contains(IPAddress.Parse("fd00::1")));
        Assert.True(new LocalSubnet(IPAddress.Parse("fd00::1"), 64).Contains(IPAddress.Parse("fd00::ffff")));
        Assert.True(new LocalSubnet(IPAddress.Parse("1.2.3.4"), 0).Contains(IPAddress.Parse("9.9.9.9")));
    }

    [Fact]
    public void TrustedNetworkStore_ApprovesAndWithdraws()
    {
        var store = new TrustedNetworkStore(_directory);
        int changes = 0;
        store.Changed += (_, _) => changes++;
        Assert.False(store.IsApproved(Networks.College().Id));
        Assert.True(store.Approve(Networks.College(), Now));
        Assert.True(store.IsApproved(Networks.College().Id));
        var approved = Assert.Single(new TrustedNetworkStore(_directory).Approved);
        Assert.Equal("eduroam", approved.Name);
        Assert.Equal(Now, approved.Approved);
        string before = File.ReadAllText(Path.Combine(_directory, TrustedNetworkStore.FileName));
        store.Revoke(Networks.College().Id);
        Assert.False(store.IsApproved(Networks.College().Id));
        Assert.False(new TrustedNetworkStore(_directory).IsApproved(Networks.College().Id));
        // Withdrawn stays withdrawn for this session, whatever another window writes.
        File.WriteAllText(Path.Combine(_directory, TrustedNetworkStore.FileName), before);
        Assert.False(store.IsApproved(Networks.College().Id));
        Assert.True(store.Approve(Networks.College(), Now));
        Assert.True(store.IsApproved(Networks.College().Id));
        Assert.Equal(3, changes);
        Assert.False(store.IsApproved(""));
    }

    [Fact]
    public void TrustedNetworkStore_ReadsBadFilesLeniently()
    {
        File.WriteAllText(Path.Combine(_directory, TrustedNetworkStore.FileName), """{"networks":[{"id":"x","approved":3}],"v":2}""");
        var store = new TrustedNetworkStore(_directory);
        Assert.True(store.IsApproved("x"));
        Assert.Null(Assert.Single(store.Approved).Approved);
        File.WriteAllText(Path.Combine(_directory, TrustedNetworkStore.FileName), "garbage");
        Assert.Empty(new TrustedNetworkStore(_directory).Approved);
        Assert.Single(Directory.GetFiles(_directory, "companion-networks.unreadable-*.json"));
    }

    [Fact]
    public void RateLimiter_CountsPerAddress()
    {
        var limiter = new CompanionRateLimiter();
        var a = IPAddress.Parse("192.168.1.5");
        var b = IPAddress.Parse("192.168.1.6");
        for (int i = 0; i < CompanionRateLimiter.MaxFailures - 1; i++) limiter.RecordFailure(a, Now);
        Assert.False(limiter.IsBlocked(a, Now));
        limiter.RecordFailure(IPAddress.Parse("::ffff:192.168.1.5"), Now);
        Assert.True(limiter.IsBlocked(a, Now));
        Assert.False(limiter.TryRequest(a, Now));
        Assert.True(limiter.TryRequest(b, Now));
        Assert.False(limiter.IsBlocked(a, Now + CompanionRateLimiter.Window));
        // b made one request above.
        for (int i = 1; i < CompanionRateLimiter.MaxRequestsPerWindow; i++) Assert.True(limiter.TryRequest(b, Now));
        Assert.False(limiter.TryRequest(b, Now));
        Assert.True(limiter.TryRequest(b, Now + CompanionRateLimiter.Window));
    }

    // MARK: - Firewall

    private const string App = @"C:\Program Files\CompleteScanner\CompleteScanner.exe";

    private static FirewallRule Rule(bool allow, FirewallProfiles profiles, string path = App, bool enabled = true,
                                     bool inbound = true, int protocol = 6, string ports = "*", string name = "CompleteScanner") =>
        new(name, path, inbound, allow, enabled, profiles, protocol, ports);

    [Fact]
    public void Firewall_BlockRuleWins()
    {
        var rules = new[] { Rule(true, FirewallProfiles.Private), Rule(false, FirewallProfiles.Public, name: "Block public") };
        Assert.Equal(CompanionFirewallVerdict.Allowed, CompanionFirewall.Evaluate(rules, App, FirewallProfiles.Private, true, 52731));
        Assert.Equal(CompanionFirewallVerdict.Blocked, CompanionFirewall.Evaluate(rules, App, FirewallProfiles.Public, true, 52731));
        Assert.Equal(CompanionFirewallVerdict.Blocked,
                     CompanionFirewall.Evaluate(rules, App, FirewallProfiles.Public | FirewallProfiles.Private, true, 52731));
        Assert.Equal(["Block public"], CompanionFirewall.BlockingRules(rules, App));
    }

    [Fact]
    public void Firewall_CountsOnlyTheProfilesOfTheNetworksReceivedOn()
    {
        // Allowed for Private at the firewall's question, which blocks Public; a virtual switch (WSL,
        // Hyper-V) or a VPN that Windows treats as public is connected too.
        var rules = new[] { Rule(true, FirewallProfiles.Private), Rule(false, FirewallProfiles.Public, name: "Block public") };
        var home = new CompanionNetworkState(Network("{home}", CompanionNetworkCategory.Private), NetworkTrust.Private);
        var virtualSwitch = new CompanionNetworkState(Network("{vswitch}", CompanionNetworkCategory.Public), NetworkTrust.NotTrusted);
        var profiles = CompanionFirewall.ProfilesFor([home, virtualSwitch]);
        Assert.Equal(FirewallProfiles.Private, profiles);
        Assert.Equal(CompanionFirewallVerdict.Allowed, CompanionFirewall.Evaluate(rules, App, profiles, true, 52731));
        Assert.Empty(CompanionFirewall.BlockingRules(rules, App, profiles));
        Assert.Equal(["Block public"], CompanionFirewall.BlockingRules(rules, App));

        // A public network the user allowed counts with its profile, and is blocked here.
        var school = new CompanionNetworkState(Network("{school}", CompanionNetworkCategory.Public), NetworkTrust.Approved);
        profiles = CompanionFirewall.ProfilesFor([home, school]);
        Assert.Equal(FirewallProfiles.Private | FirewallProfiles.Public, profiles);
        Assert.Equal(CompanionFirewallVerdict.Blocked, CompanionFirewall.Evaluate(rules, App, profiles, true, 52731));
        Assert.Equal(["Block public"], CompanionFirewall.BlockingRules(rules, App, profiles));

        // Received on nowhere yet: every connected network may be allowed next, so all of them count.
        var work = new CompanionNetworkState(Network("{work}", CompanionNetworkCategory.Domain), NetworkTrust.NotTrusted);
        Assert.Equal(FirewallProfiles.Public | FirewallProfiles.Domain, CompanionFirewall.ProfilesFor([virtualSwitch, work]));
        Assert.Equal(FirewallProfiles.None, CompanionFirewall.ProfilesFor([]));
    }

    private static CompanionNetwork Network(string id, CompanionNetworkCategory category) =>
        new(id, id, category, [new CompanionNetworkInterface(1, "adapter" + id, [new LocalSubnet(IPAddress.Parse("192.168.1.2"), 24)])]);

    [Fact]
    public void Firewall_AsksWhenNoRuleApplies()
    {
        var rules = new[]
        {
            Rule(false, FirewallProfiles.Public, enabled: false),
            Rule(false, FirewallProfiles.Public, inbound: false),
            Rule(false, FirewallProfiles.Public, path: @"C:\Other\App.exe"),
            Rule(false, FirewallProfiles.Public, protocol: 17),
            Rule(false, FirewallProfiles.Public, ports: "80,443"),
            Rule(false, FirewallProfiles.Domain),
        };
        Assert.Equal(CompanionFirewallVerdict.WillAsk, CompanionFirewall.Evaluate(rules, App, FirewallProfiles.Public, true, 52731));
        Assert.Equal(CompanionFirewallVerdict.Off, CompanionFirewall.Evaluate(rules, App, FirewallProfiles.Public, false, 52731));
        Assert.Equal(CompanionFirewallVerdict.Blocked,
                     CompanionFirewall.Evaluate([Rule(false, FirewallProfiles.All, path: App.ToUpperInvariant(), protocol: 256)],
                                                App, FirewallProfiles.Public, true, 52731));
    }

    [Theory]
    [InlineData("*", true)]
    [InlineData("", true)]
    [InlineData("52731", true)]
    [InlineData("80, 52700-52800", true)]
    [InlineData("80,443", false)]
    [InlineData("52732-52800", false)]
    [InlineData("RPC", false)]
    public void Firewall_PortRanges(string ports, bool matches) => Assert.Equal(matches, CompanionFirewall.PortMatches(ports, 52731));

    // MARK: - Phone checks

    private static CompanionNetworkState State(CompanionNetwork network, NetworkTrust trust) => new(network, trust);

    [Fact]
    public void Checks_PublicNetworkNotApproved()
    {
        var snapshot = new CompanionSnapshot
        {
            Networks = [State(Networks.College(), NetworkTrust.NotTrusted)],
            Listen = CompanionListenState.NoTrustedNetwork,
            Firewall = CompanionFirewallVerdict.WillAsk,
            PairedCount = 1,
        };
        var checks = CompanionTroubleshooter.Diagnose(snapshot);
        Assert.Equal([$"phoneNetwork:{Networks.College().Id}", "phoneFirewall", "phoneIsolation"], checks.Select(c => c.Id));
        var network = checks[0];
        Assert.Equal(CheckStatus.Warning, network.Status);
        Assert.Equal("Not receiving on eduroam", network.Title);
        Assert.Contains("as a public network", network.Detail);
        Assert.Contains("Allow receiving on this network", network.Detail);
        Assert.Equal([TroubleshootAction.OpenNetworkSettings], network.Actions);
        Assert.Equal("1 warning found.", CompanionTroubleshooter.Summary(checks));
        Assert.Equal("Not receiving from phones on eduroam.", CompanionTroubleshooter.Headline(snapshot));
        Assert.Equal(CheckStatus.Tip, checks[2].Status);
        Assert.Contains("hotspot", checks[2].Detail);
    }

    [Fact]
    public void Checks_ApprovedPublicNetworkMentionsTheFirewallQuestion()
    {
        var snapshot = new CompanionSnapshot
        {
            Networks = [State(Networks.College(), NetworkTrust.Approved)],
            Listen = CompanionListenState.Listening,
            Port = 52731,
            Firewall = CompanionFirewallVerdict.WillAsk,
            PairedCount = 2,
        };
        var checks = CompanionTroubleshooter.Diagnose(snapshot);
        Assert.Equal(["phoneListening", $"phoneNetwork:{Networks.College().Id}", "phoneFirewall", "phoneIsolation"], checks.Select(c => c.Id));
        Assert.Equal("Listening on port 52731. 2 phones are paired.", checks[0].Detail);
        Assert.Equal("Receiving on eduroam, which you allowed", checks[1].Title);
        Assert.Equal("Paired phones on this network can send documents to this PC.", checks[1].Detail);
        Assert.Contains("Public networks ticked", checks[2].Detail);
        Assert.Equal("Nothing here stops a paired phone from connecting.", CompanionTroubleshooter.Summary(checks));
        Assert.Equal("Receiving from phones on eduroam.", CompanionTroubleshooter.Headline(snapshot));
    }

    [Fact]
    public void Checks_FirewallBlockIsAProblem()
    {
        var snapshot = new CompanionSnapshot
        {
            Networks = [State(Networks.Home(), NetworkTrust.Private)],
            Listen = CompanionListenState.Listening,
            Port = 52731,
            Firewall = CompanionFirewallVerdict.Blocked,
            BlockingRules = ["completescanner.exe"],
            PairedCount = 1,
        };
        var checks = CompanionTroubleshooter.Diagnose(snapshot);
        Assert.Equal("phoneFirewall", checks[0].Id);
        Assert.Equal(CheckStatus.Problem, checks[0].Status);
        Assert.Contains("\"completescanner.exe\"", checks[0].Detail);
        Assert.Contains("wf.msc", checks[0].Detail);
        Assert.Equal("Home Wi-Fi is a private network", checks.Single(c => c.Id.StartsWith("phoneNetwork:")).Title);
        Assert.Equal("1 problem found.", CompanionTroubleshooter.Summary(checks));
    }

    [Fact]
    public void Checks_SayWhyNothingListens()
    {
        var off = CompanionTroubleshooter.Diagnose(new CompanionSnapshot { Listen = CompanionListenState.Off, Firewall = CompanionFirewallVerdict.WillAsk });
        Assert.Equal(["phoneIsolation", "phoneListening"], off.Select(c => c.Id).OrderBy(id => id));
        Assert.Equal("No phone is paired", off.Single(c => c.Id == "phoneListening").Title);
        Assert.DoesNotContain(off, c => c.Id == "phoneFirewall");
        var offline = CompanionTroubleshooter.Diagnose(new CompanionSnapshot { Listen = CompanionListenState.Offline });
        Assert.Equal(CheckStatus.Problem, offline[0].Status);
        Assert.Equal("Not connected to a network", offline[0].Title);
        var failed = CompanionTroubleshooter.Diagnose(new CompanionSnapshot { Listen = CompanionListenState.Failed, ListenError = "Port in use" });
        Assert.StartsWith("Port in use. Close other copies", failed[0].Detail);
        var elsewhere = CompanionTroubleshooter.Diagnose(new CompanionSnapshot { Listen = CompanionListenState.Elsewhere });
        Assert.Equal(CheckStatus.Warning, elsewhere[0].Status);
        var pairing = CompanionTroubleshooter.Diagnose(new CompanionSnapshot
        {
            Listen = CompanionListenState.Listening, Port = 5000, PairingOpen = true, Firewall = CompanionFirewallVerdict.Allowed,
        });
        Assert.Equal("Listening on port 5000 while the pairing code is shown.", pairing.Single(c => c.Id == "phoneListening").Detail);
        Assert.Equal(CheckStatus.Ok, pairing.Single(c => c.Id == "phoneFirewall").Status);
    }

    [Fact]
    public void Checks_SuggestTheCloudFolderWhenPhonesStayAway()
    {
        var quiet = new CompanionSnapshot
        {
            Networks = [State(Networks.Home(), NetworkTrust.Private)],
            Listen = CompanionListenState.Listening,
            Port = 52731,
            PairedCount = 1,
            PhonesQuietFor = TimeSpan.FromDays(4.5),
        };
        var check = CompanionTroubleshooter.Diagnose(quiet).Single(c => c.Id == "phoneSyncFolder");
        Assert.Equal(CheckStatus.Tip, check.Status);
        Assert.Contains("for 4 days", check.Detail);
        Assert.Contains("OneDrive or iCloud Drive", check.Detail);
        Assert.Equal("phoneIsolation", CompanionTroubleshooter.Diagnose(quiet)[^1].Id);
        Assert.DoesNotContain(CompanionTroubleshooter.Diagnose(quiet with { SyncFolderChosen = true }), c => c.Id == "phoneSyncFolder");
        Assert.DoesNotContain(CompanionTroubleshooter.Diagnose(quiet with { PhonesQuietFor = TimeSpan.FromDays(1) }), c => c.Id == "phoneSyncFolder");
        Assert.DoesNotContain(CompanionTroubleshooter.Diagnose(quiet with { PairedCount = 0, PhonesQuietFor = null }), c => c.Id == "phoneSyncFolder");
    }
}
