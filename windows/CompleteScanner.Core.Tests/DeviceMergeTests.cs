using CompleteScanner.Core;
using Xunit;

namespace CompleteScanner.Core.Tests;

// Mirrored by Tests/CompleteScannerTests/DeviceMergeTests.swift: same tables, same cases.

public class DeviceMergeTests
{
    private static ScannerInfo Wia(string name, string? model = null, string id = "1") =>
        new($"wia:{name}#{id}", name, "WIA", Backend: "wia", Model: model);

    private static ScannerInfo Twain(string name, string id = "1") =>
        new($"twain:{name}#{id}", name, "USB", Backend: "twain");

    private static ScannerInfo Escl(string name, string? uuid = null, string id = "1") =>
        new($"escl:{name}#{id}", name, "Network", Backend: "escl", Model: name, HardwareId: uuid);

    private static ScannerInfo Ic(string name, string transport) =>
        new($"ic:{transport}:{name}", name, transport, Backend: "ic");

    private static readonly ScannerInfo Demo = new("mock:demo", "Demo Scanner", "Demo", IsDemo: true, Backend: "mock");

    // MARK: - Model keys

    public static TheoryData<string, string> ModelKeys => new()
    {
        { "EPSON Perfection V600 Photo", "epson perfection v600 photo" },
        { "HP LaserJet MFP M428fdw (192.168.1.20)", "hp laserjet mfp m428fdw" },
        { "Hewlett-Packard ScanJet 200 TWAIN", "hp scanjet 200" },
        { "SEIKO EPSON DS-530 Series", "epson 530" },
        { "Kodak Alaris i2600 Scanner", "kodak i2600" },
        { "Brother MFC-L2710DW fe80::1c2b:3d4e:5f60:7a8b%12", "brother mfc l2710dw" },
        { "Canon MF743C 10.0.0.7:8080", "canon mf743c" },
        { "WIA-Brother ADS-2200 64-bit driver", "brother ads 2200" },
        { "Fujitsu fi-7160 x64 USB", "fujitsu fi 7160" },
        { "Epson ES-400 epson ES-400", "epson es 400" },
        { "Canon LiDE 300 [WSD] {TWAIN}", "canon lide 300" },
        { "Ricoh Café 7500", "ricoh caf 7500" },
        { "Scanner (USB)", "" },
    };

    [Theory]
    [MemberData(nameof(ModelKeys))]
    public void ModelKey_NormalizesNames(string name, string expected)
    {
        Assert.Equal(expected, DeviceMerge.ModelKey(name));
    }

    // MARK: - Same device

    public static TheoryData<string, ScannerInfo, ScannerInfo, bool> Pairs => new()
    {
        { "WIA V600 and TWAIN V600 Photo", Wia("EPSON Perfection V600"), Twain("EPSON Perfection V600 Photo"), true },
        { "different hardware ids stay apart", Escl("HP M428", "uuid-a"), new("twain:m428", "HP M428", "USB", Backend: "twain", HardwareId: "uuid-b"), false },
        { "equal hardware ids match whatever the names", Escl("HP M428", "uuid-a"), new("twain:x", "Office printer", "USB", Backend: "twain", HardwareId: "UUID-A"), true },
        { "hardware ids compare without urn prefix, case or dashes", Escl("HP M428", "urn:uuid:4509A320-00A0-008F"), new("twain:x", "Other", "USB", Backend: "twain", HardwareId: "4509a32000a0008f"), true },
        { "one hardware id: the names decide", Escl("HP LaserJet MFP M428fdw", "uuid-a"), Wia("HP LaserJet MFP M428fdw"), true },
        { "same backend and transport never merge", Wia("Canon LiDE 300", id: "1"), Wia("Canon LiDE 300", id: "2"), false },
        { "demo devices never merge", Demo, Wia("Demo Scanner"), false },
        { "containment without a model number", Wia("HP Scanjet"), Twain("HP Scanjet Pro"), false },
        { "containment sharing one word", Wia("Canon"), Twain("Canon LiDE 300"), false },
        { "neither contains the other", Wia("Epson ET-2850"), Twain("Epson ET-4850"), false },
        { "equal words without a digit", Wia("Plustek OpticSlim"), Twain("Plustek OpticSlim TWAIN"), true },
        { "the model matches when the name does not", Wia("Office scanner", model: "Canon Canon LiDE 300"), Twain("Canon LiDE 300"), true },
        { "the name matches when the model is generic", Wia("EPSON Perfection V600", model: "EPSON WIA Scanner Device"), Twain("EPSON Perfection V600 Photo"), true },
        { "names without model words never match", Wia("Scanner"), Twain("TWAIN Scanner"), false },
        { "macOS USB and Bonjour entries", Ic("Brother MFC-L2710DW series", "USB"), Ic("Brother MFC-L2710DW", "Network"), true },
    };

    [Theory]
    [MemberData(nameof(Pairs))]
    public void SameDevice_FollowsTheRules(string name, ScannerInfo a, ScannerInfo b, bool expected)
    {
        Assert.True(expected == DeviceMerge.SameDevice(a, b), name);
        Assert.True(expected == DeviceMerge.SameDevice(b, a), name + " (swapped)");
    }

    // MARK: - Grouping and ranking

    [Fact]
    public void Group_MergesWiaAndTwainAndPrefersWia()
    {
        var twain = Twain("EPSON Perfection V600 Photo");
        var wia = Wia("EPSON Perfection V600");
        var groups = DeviceMerge.Group([twain, wia], DeviceMerge.WindowsRanking);

        var group = Assert.Single(groups);
        Assert.Equal("model:epson perfection v600", group.Key);
        Assert.Same(wia, group.Primary);
        Assert.Equal([twain, wia], group.Members);
    }

    [Fact]
    public void Group_KeyDoesNotDependOnListOrder()
    {
        var a = DeviceMerge.Group([Twain("EPSON Perfection V600 Photo"), Wia("EPSON Perfection V600")], DeviceMerge.WindowsRanking);
        var b = DeviceMerge.Group([Wia("EPSON Perfection V600"), Twain("EPSON Perfection V600 Photo")], DeviceMerge.WindowsRanking);
        Assert.Equal(a[0].Key, b[0].Key);
    }

    [Fact]
    public void Group_KeyIsTheHardwareIdWhenAMemberHasOne()
    {
        var wia = Wia("HP LaserJet MFP M428fdw");
        var escl = Escl("HP LaserJet MFP M428fdw", "4509A320-00A0");
        var group = Assert.Single(DeviceMerge.Group([escl, wia], DeviceMerge.WindowsRanking));
        Assert.Equal("id:4509a32000a0", group.Key);
        Assert.Same(wia, group.Primary);
    }

    [Fact]
    public void Group_RanksNetworkAboveTwain()
    {
        var twain = Twain("Brother MFC-L2710DW");
        var escl = Escl("Brother MFC-L2710DW", "uuid-1");
        Assert.Same(escl, Assert.Single(DeviceMerge.Group([twain, escl], DeviceMerge.WindowsRanking)).Primary);
    }

    [Fact]
    public void Group_MacRankingPrefersUsb()
    {
        var bonjour = Ic("Brother MFC-L2710DW", "Network");
        var usb = Ic("Brother MFC-L2710DW series", "USB");
        var shared = Ic("Brother MFC-L2710DW", "Shared");
        var group = Assert.Single(DeviceMerge.Group([shared, bonjour, usb], DeviceMerge.MacRanking));
        Assert.Same(usb, group.Primary);
        Assert.Equal(3, group.Members.Count);
    }

    [Fact]
    public void Group_IosRankingPrefersTheScannersOwnNetworkConnection()
    {
        Assert.Equal(["escl:Network", "companion:*"], DeviceMerge.IosRanking);
        // The same scanner through a computer (the desktop companion) and on its own network connection.
        var companion = new ScannerInfo("companion:pc:1", "HP LaserJet MFP M428fdw", "Desktop", Backend: "companion",
                                        HardwareId: "4509A320-00A0");
        var escl = Escl("HP LaserJet MFP M428fdw", "4509a320-00a0");
        var group = Assert.Single(DeviceMerge.Group([companion, escl], DeviceMerge.IosRanking));
        Assert.Same(escl, group.Primary);
        Assert.Equal("id:4509a32000a0", group.Key);
        // A connection the phone does not rank comes after the companion; the demo scanner stays apart.
        var other = new ScannerInfo("x:1", "Canon LiDE 300", "Bluetooth", Backend: "other");
        var viaComputer = new ScannerInfo("companion:pc:2", "Canon LiDE 300", "Desktop", Backend: "companion");
        Assert.Same(viaComputer, Assert.Single(DeviceMerge.Group([other, viaComputer], DeviceMerge.IosRanking)).Primary);
        Assert.Equal(2, DeviceMerge.Group([Demo, escl], DeviceMerge.IosRanking).Count);
    }

    [Fact]
    public void Group_UnrankedConnectionsComeLastInListOrder()
    {
        var first = new ScannerInfo("x:1", "Canon LiDE 300", "Bluetooth", Backend: "other");
        var second = new ScannerInfo("y:1", "Canon LiDE 300", "Infrared", Backend: "else");
        Assert.Same(first, Assert.Single(DeviceMerge.Group([first, second], DeviceMerge.WindowsRanking)).Primary);
        var twain = Twain("Canon LiDE 300");
        Assert.Same(twain, Assert.Single(DeviceMerge.Group([first, twain], DeviceMerge.WindowsRanking)).Primary);
    }

    [Fact]
    public void Group_OverrideWins()
    {
        var wia = Wia("EPSON Perfection V600");
        var twain = Twain("EPSON Perfection V600 Photo");
        var overrides = new Dictionary<string, string> { ["model:epson perfection v600"] = "TWAIN:usb" };
        Assert.Same(twain, Assert.Single(DeviceMerge.Group([wia, twain], DeviceMerge.WindowsRanking, overrides)).Primary);
    }

    [Fact]
    public void Group_OverrideForAMissingConnectionFallsBackToRanking()
    {
        var wia = Wia("EPSON Perfection V600");
        var twain = Twain("EPSON Perfection V600 Photo");
        var overrides = new Dictionary<string, string> { ["model:epson perfection v600"] = "escl:Network" };
        Assert.Same(wia, Assert.Single(DeviceMerge.Group([twain, wia], DeviceMerge.WindowsRanking, overrides)).Primary);
    }

    [Fact]
    public void Group_TwoIdenticalScannersStayTwoRowsWithUniqueKeys()
    {
        var wia1 = Wia("Canon LiDE 300", id: "1");
        var wia2 = Wia("Canon LiDE 300", id: "2");
        var twain1 = Twain("Canon LiDE 300", id: "1");
        var twain2 = Twain("Canon LiDE 300", id: "2");
        var groups = DeviceMerge.Group([wia1, wia2, twain1, twain2], DeviceMerge.WindowsRanking);

        Assert.Equal(2, groups.Count);
        Assert.Equal(["model:canon lide 300", "model:canon lide 300#2"], groups.Select(g => g.Key));
        Assert.Equal([wia1, twain1], groups[0].Members);
        Assert.Equal([wia2, twain2], groups[1].Members);
    }

    [Fact]
    public void Group_KeepsDemoAndUnnamedDevicesApartInListOrder()
    {
        var wia = Wia("Demo Scanner");
        var unnamed = Twain("Scanner");
        var groups = DeviceMerge.Group([Demo, wia, unnamed], DeviceMerge.WindowsRanking);

        Assert.Equal(["device:mock:demo", "model:demo", "device:twain:Scanner#1"], groups.Select(g => g.Key));
        Assert.All(groups, g => Assert.Single(g.Members));
        Assert.Same(Demo, groups[0].Primary);
    }

    [Fact]
    public void Group_OfNothingIsEmpty()
    {
        Assert.Empty(DeviceMerge.Group([], DeviceMerge.WindowsRanking));
    }

    // MARK: - Connections and diagnostics

    [Fact]
    public void Connections_HaveIdsAndLabels()
    {
        Assert.Equal("wia:WIA", DeviceMerge.ConnectionId(Wia("A")));
        Assert.Equal("escl:Network", DeviceMerge.ConnectionId(Escl("A")));
        Assert.Equal("WIA", DeviceMerge.ConnectionLabel(Wia("A")));
        Assert.Equal("TWAIN", DeviceMerge.ConnectionLabel(Twain("A")));
        Assert.Equal("Network (eSCL)", DeviceMerge.ConnectionLabel(Escl("A")));
        Assert.Equal("Demo", DeviceMerge.ConnectionLabel(Demo));
        Assert.Equal("USB", DeviceMerge.ConnectionLabel(Ic("A", "USB")));
    }

    [Fact]
    public void DiagnosticsReport_ListsRawNamesAndKeys()
    {
        var groups = DeviceMerge.Group([Twain("EPSON Perfection V600 Photo"), Wia("EPSON Perfection V600", model: "EPSON EPSON Perfection V600")],
                                       DeviceMerge.WindowsRanking);
        Assert.Equal(
            "model:epson perfection v600 -> wia:WIA \"wia:EPSON Perfection V600#1\"\n"
            + "  twain:USB id=\"twain:EPSON Perfection V600 Photo#1\" name=\"EPSON Perfection V600 Photo\" model=\"\" hardwareId=\"\" key=\"epson perfection v600 photo\"\n"
            + "  wia:WIA id=\"wia:EPSON Perfection V600#1\" name=\"EPSON Perfection V600\" model=\"EPSON EPSON Perfection V600\" hardwareId=\"\" key=\"epson perfection v600\"\n",
            DeviceMerge.DiagnosticsReport(groups));
    }
}
