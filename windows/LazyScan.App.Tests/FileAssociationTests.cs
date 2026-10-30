using LazyScan.App.Services;
using Microsoft.Win32;
using Xunit;

namespace LazyScan.App.Tests;

// The .lsdoc association is written under a key of the tests' own in HKCU\Software, removed again
// afterwards; the user's real Software\Classes is never touched.

public sealed class FileAssociationTests : IDisposable
{
    private readonly string _keyPath = @"Software\LazyScan.Tests-" + Guid.NewGuid().ToString("N");

    public void Dispose() => Registry.CurrentUser.DeleteSubKeyTree(_keyPath, throwOnMissingSubKey: false);

    private const string Exe = @"C:\Program Files\Lazy Scan\LazyScan.exe";

    [Fact]
    public void Entries_PointTheExtensionAtTheApp()
    {
        Assert.Equal(
            [
                (".lsdoc", "LazyScan.Package"),
                ("LazyScan.Package", "Lazy Scan document"),
                (@"LazyScan.Package\DefaultIcon", "\"C:\\Program Files\\Lazy Scan\\LazyScan.exe\",0"),
                (@"LazyScan.Package\shell\open\command", "\"C:\\Program Files\\Lazy Scan\\LazyScan.exe\" \"%1\""),
            ],
            FileAssociation.Entries(Exe));
    }

    [Fact]
    public void Register_WritesOnceAndFollowsTheExe()
    {
        using var classes = Registry.CurrentUser.CreateSubKey(_keyPath);
        Assert.True(FileAssociation.Register(classes, Exe));
        foreach (var (name, value) in FileAssociation.Entries(Exe))
        {
            using var key = classes.OpenSubKey(name);
            Assert.Equal(value, key?.GetValue(""));
        }
        // A second start changes nothing; a moved exe is followed.
        Assert.False(FileAssociation.Register(classes, Exe));
        Assert.True(FileAssociation.Register(classes, @"D:\Apps\LazyScan.exe"));
        using var command = classes.OpenSubKey(@"LazyScan.Package\shell\open\command");
        Assert.Equal("\"D:\\Apps\\LazyScan.exe\" \"%1\"", command?.GetValue(""));
    }
}
