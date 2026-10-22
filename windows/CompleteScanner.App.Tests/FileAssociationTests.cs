using CompleteScanner.App.Services;
using Microsoft.Win32;
using Xunit;

namespace CompleteScanner.App.Tests;

// The .csdoc association is written under a key of the tests' own in HKCU\Software, removed again
// afterwards; the user's real Software\Classes is never touched.

public sealed class FileAssociationTests : IDisposable
{
    private readonly string _keyPath = @"Software\CompleteScanner.Tests-" + Guid.NewGuid().ToString("N");

    public void Dispose() => Registry.CurrentUser.DeleteSubKeyTree(_keyPath, throwOnMissingSubKey: false);

    private const string Exe = @"C:\Program Files\CompleteScanner\CompleteScanner.exe";

    [Fact]
    public void Entries_PointTheExtensionAtTheApp()
    {
        Assert.Equal(
            [
                (".csdoc", "CompleteScanner.Package"),
                ("CompleteScanner.Package", "CompleteScanner document"),
                (@"CompleteScanner.Package\DefaultIcon", "\"C:\\Program Files\\CompleteScanner\\CompleteScanner.exe\",0"),
                (@"CompleteScanner.Package\shell\open\command", "\"C:\\Program Files\\CompleteScanner\\CompleteScanner.exe\" \"%1\""),
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
        Assert.True(FileAssociation.Register(classes, @"D:\Apps\CompleteScanner.exe"));
        using var command = classes.OpenSubKey(@"CompleteScanner.Package\shell\open\command");
        Assert.Equal("\"D:\\Apps\\CompleteScanner.exe\" \"%1\"", command?.GetValue(""));
    }
}
