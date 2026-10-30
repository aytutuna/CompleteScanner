using System.Collections;
using System.Diagnostics;
using System.Reflection;
using LazyScan.Core;

namespace LazyScan.App.Services.Companion;

/// <summary>What Windows Defender Firewall's settings say about this app, read once.</summary>
/// <param name="CurrentProfiles">The profiles of every connected network (CurrentProfileTypes).</param>
/// <param name="Enabled">The firewall is on for one of <paramref name="CurrentProfiles"/>.</param>
/// <param name="EnabledProfiles">The profiles the firewall is on for, connected or not.</param>
public sealed record FirewallState(bool Read, FirewallProfiles CurrentProfiles, bool Enabled, IReadOnlyList<FirewallRule> Rules,
                                   FirewallProfiles EnabledProfiles = FirewallProfiles.All)
{
    public static FirewallState Unknown { get; } = new(false, FirewallProfiles.None, true, []);

    /// <summary>
    /// The verdict for the app at <paramref name="applicationPath"/> on <paramref name="port"/>, on
    /// networks of <paramref name="networkProfiles"/> (<see cref="CompanionFirewall.ProfilesFor"/>);
    /// on every connected network's profile when that is None.
    /// </summary>
    public CompanionFirewallVerdict Verdict(string applicationPath, int port, FirewallProfiles networkProfiles = FirewallProfiles.None)
    {
        if (!Read) return CompanionFirewallVerdict.Unknown;
        if (networkProfiles == FirewallProfiles.None) return CompanionFirewall.Evaluate(Rules, applicationPath, CurrentProfiles, Enabled, port);
        var active = ActiveProfiles(networkProfiles);
        return CompanionFirewall.Evaluate(Rules, applicationPath, active, active != FirewallProfiles.None, port);
    }

    /// <summary>The names of the rules that block the app on networks of <paramref name="networkProfiles"/> (every profile when None).</summary>
    public IReadOnlyList<string> BlockingRules(string applicationPath, FirewallProfiles networkProfiles = FirewallProfiles.None) =>
        !Read ? []
        : networkProfiles == FirewallProfiles.None ? CompanionFirewall.BlockingRules(Rules, applicationPath)
        : CompanionFirewall.BlockingRules(Rules, applicationPath, ActiveProfiles(networkProfiles));

    /// <summary>Those of <paramref name="networkProfiles"/> the firewall is on for.</summary>
    private FirewallProfiles ActiveProfiles(FirewallProfiles networkProfiles) => networkProfiles & EnabledProfiles;
}

/// <summary>
/// Reads Windows Defender Firewall's current profiles and its rules for one program through
/// HNetCfg.FwPolicy2 (COM, late bound, no administrator rights). It only reads: no rule is ever
/// added, changed or removed, and no firewall setting is touched.
/// </summary>
public static class FirewallReader
{
    /// <summary>The firewall's state for <paramref name="applicationPath"/>; <see cref="FirewallState.Unknown"/> when it cannot be read. Never throws.</summary>
    public static FirewallState Read(string applicationPath)
    {
        object? policy = null;
        try
        {
            var type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2", throwOnError: false);
            if (type is null) return FirewallState.Unknown;
            policy = Activator.CreateInstance(type);
            if (policy is null) return FirewallState.Unknown;
            var profiles = (FirewallProfiles)Convert.ToInt32(Get(policy, "CurrentProfileTypes"), System.Globalization.CultureInfo.InvariantCulture);
            var enabledProfiles = FirewallProfiles.None;
            foreach (var profile in new[] { FirewallProfiles.Domain, FirewallProfiles.Private, FirewallProfiles.Public })
            {
                if (Convert.ToBoolean(Get(policy, "FirewallEnabled", (int)profile), System.Globalization.CultureInfo.InvariantCulture))
                {
                    enabledProfiles |= profile;
                }
            }
            bool enabled = (enabledProfiles & profiles) != 0;
            var rules = new List<FirewallRule>();
            if (Get(policy, "Rules") is IEnumerable all)
            {
                foreach (object? rule in all)
                {
                    if (rule is null) continue;
                    try
                    {
                        string path = Get(rule, "ApplicationName") as string ?? "";
                        if (!string.Equals(Environment.ExpandEnvironmentVariables(path), applicationPath, StringComparison.OrdinalIgnoreCase))
                        {
                            continue;
                        }
                        rules.Add(new FirewallRule(
                            Get(rule, "Name") as string ?? "",
                            path,
                            Convert.ToInt32(Get(rule, "Direction"), System.Globalization.CultureInfo.InvariantCulture) == 1,
                            Convert.ToInt32(Get(rule, "Action"), System.Globalization.CultureInfo.InvariantCulture) == 1,
                            Convert.ToBoolean(Get(rule, "Enabled"), System.Globalization.CultureInfo.InvariantCulture),
                            (FirewallProfiles)Convert.ToInt32(Get(rule, "Profiles"), System.Globalization.CultureInfo.InvariantCulture),
                            Convert.ToInt32(Get(rule, "Protocol"), System.Globalization.CultureInfo.InvariantCulture),
                            Get(rule, "LocalPorts") as string ?? "*"));
                    }
                    finally
                    {
                        if (OperatingSystem.IsWindows()) System.Runtime.InteropServices.Marshal.ReleaseComObject(rule);
                    }
                }
            }
            return new FirewallState(true, profiles, enabled, rules, enabledProfiles);
        }
        catch (Exception e)
        {
            // Never throws: the phone checks then show no firewall check.
            Trace.TraceWarning($"Could not read the firewall settings: {e.Message}");
            return FirewallState.Unknown;
        }
        finally
        {
            if (policy is not null && OperatingSystem.IsWindows()) System.Runtime.InteropServices.Marshal.ReleaseComObject(policy);
        }
    }

    /// <summary>A property of a late-bound COM object (with its index for a parameterized one).</summary>
    private static object? Get(object target, string name, params object[] index) =>
        target.GetType().InvokeMember(name, BindingFlags.GetProperty, binder: null, target, index.Length == 0 ? null : index,
                                      System.Globalization.CultureInfo.InvariantCulture);
}
