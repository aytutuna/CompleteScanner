namespace CompleteScanner.Core;

// What Windows Defender Firewall's rules mean for the companion server. The app reads the rules
// (HNetCfg.FwPolicy2, no administrator rights, nothing changed); the decision is here so it can be
// tested. C# only, like WindowsSystemStatus.cs.

/// <summary>Firewall profiles (NET_FW_PROFILE_TYPE2), as a bit mask.</summary>
[Flags]
public enum FirewallProfiles
{
    None = 0,
    Domain = 1,
    Private = 2,
    Public = 4,
    All = 0x7FFFFFFF,
}

/// <summary>One firewall rule, as read.</summary>
/// <param name="ApplicationPath">The program it applies to; "" for a rule for every program.</param>
/// <param name="Inbound">NET_FW_RULE_DIR_IN.</param>
/// <param name="Allow">NET_FW_ACTION_ALLOW (else block).</param>
/// <param name="Protocol">NET_FW_IP_PROTOCOL: 6 TCP, 17 UDP, 256 any.</param>
/// <param name="LocalPorts">"*", "52731", "5000-5100,6000"; "" counts as any.</param>
public sealed record FirewallRule(string Name, string ApplicationPath, bool Inbound, bool Allow, bool Enabled,
                                  FirewallProfiles Profiles, int Protocol, string LocalPorts);

/// <summary>What the firewall does to connections from phones to this app.</summary>
public enum CompanionFirewallVerdict
{
    /// <summary>The rules could not be read.</summary>
    Unknown,
    /// <summary>The firewall is off for the current network's profile.</summary>
    Off,
    /// <summary>A rule lets the app receive on the current profile.</summary>
    Allowed,
    /// <summary>A rule blocks the app on the current profile (often from a cancelled firewall prompt).</summary>
    Blocked,
    /// <summary>No rule for the app yet: Windows asks the first time the app listens.</summary>
    WillAsk,
}

public static class CompanionFirewall
{
    public const int ProtocolTcp = 6;
    public const int ProtocolAny = 256;

    /// <summary>
    /// The verdict for the app at <paramref name="applicationPath"/> listening on
    /// <paramref name="port"/> on networks of <paramref name="profiles"/>: an enabled inbound rule
    /// for the app (by its full path, case-insensitively), on one of those profiles, for TCP or any
    /// protocol and a port range holding <paramref name="port"/>, blocks (a block rule wins, as in
    /// Windows) or allows; without one the firewall asks, unless it is off.
    /// </summary>
    public static CompanionFirewallVerdict Evaluate(IReadOnlyList<FirewallRule> rules, string applicationPath,
                                                    FirewallProfiles profiles, bool firewallEnabled, int port)
    {
        if (!firewallEnabled) return CompanionFirewallVerdict.Off;
        var relevant = rules.Where(rule => rule.Enabled && rule.Inbound && (rule.Profiles & profiles) != 0
                                           && SamePath(rule.ApplicationPath, applicationPath)
                                           && rule.Protocol is ProtocolTcp or ProtocolAny
                                           && PortMatches(rule.LocalPorts, port)).ToList();
        if (relevant.Any(rule => !rule.Allow)) return CompanionFirewallVerdict.Blocked;
        if (relevant.Any(rule => rule.Allow)) return CompanionFirewallVerdict.Allowed;
        return CompanionFirewallVerdict.WillAsk;
    }

    /// <summary>
    /// The names of the enabled inbound rules that block the app on networks of
    /// <paramref name="profiles"/> (every profile by default), for the troubleshooter.
    /// </summary>
    public static IReadOnlyList<string> BlockingRules(IReadOnlyList<FirewallRule> rules, string applicationPath,
                                                      FirewallProfiles profiles = FirewallProfiles.All) =>
        [.. rules.Where(rule => rule.Enabled && rule.Inbound && !rule.Allow && (rule.Profiles & profiles) != 0
                                && SamePath(rule.ApplicationPath, applicationPath))
                 .Select(rule => rule.Name).Distinct()];

    /// <summary>The firewall profile Windows applies to a network of <paramref name="category"/>.</summary>
    public static FirewallProfiles Profile(CompanionNetworkCategory category) => category switch
    {
        CompanionNetworkCategory.Private => FirewallProfiles.Private,
        CompanionNetworkCategory.Domain => FirewallProfiles.Domain,
        _ => FirewallProfiles.Public,
    };

    /// <summary>
    /// The profiles whose rules decide whether phones reach the app: those of the networks it
    /// receives on, or, while it receives on none, those of every connected network (one of them
    /// may be allowed next). None without networks. Another adapter's profile (a VPN, or the
    /// virtual switch of Hyper-V or WSL, which Windows treats as public) does not count, so a rule
    /// that blocks the app there does not make the network it receives on look blocked.
    /// </summary>
    public static FirewallProfiles ProfilesFor(IReadOnlyList<CompanionNetworkState> networks)
    {
        var receiving = networks.Where(n => n.Trust != NetworkTrust.NotTrusted).ToList();
        return (receiving.Count > 0 ? receiving : networks)
            .Aggregate(FirewallProfiles.None, (profiles, n) => profiles | Profile(n.Network.Category));
    }

    /// <summary>Whether a rule's local ports ("*", "", "80", "5000-5100", lists of those) include <paramref name="port"/>.</summary>
    public static bool PortMatches(string localPorts, int port)
    {
        string ports = localPorts.Trim();
        if (ports.Length == 0 || ports == "*") return true;
        foreach (string part in ports.Split(','))
        {
            string item = part.Trim();
            int dash = item.IndexOf('-');
            if (dash > 0 && int.TryParse(item[..dash], out int low) && int.TryParse(item[(dash + 1)..], out int high))
            {
                if (port >= low && port <= high) return true;
            }
            else if (int.TryParse(item, out int single) && single == port)
            {
                return true;
            }
        }
        return false;
    }

    private static bool SamePath(string rulePath, string applicationPath)
    {
        if (rulePath.Length == 0 || applicationPath.Length == 0) return false;
        string a = Environment.ExpandEnvironmentVariables(rulePath).Trim().Trim('"');
        string b = applicationPath.Trim().Trim('"');
        return string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    }
}
