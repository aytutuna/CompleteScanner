using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using CompleteScanner.Core;

namespace CompleteScanner.App.Services;

/// <summary>
/// What the app can do with saved files through Windows: open, open with, show in Explorer,
/// share and copy. <see cref="AppViewModel"/> decides what to do (with
/// <see cref="SaveActions"/>); this carries it out, so tests can stand in for Windows. Every
/// member is called on the UI thread and throws when Windows refuses.
/// </summary>
public interface IFileActions
{
    /// <summary>Opens the file with its default app.</summary>
    void Open(string path);
    /// <summary>The Windows "Open with" dialog for the file; the user picks the app there (or cancels).</summary>
    void OpenWith(string path);
    /// <summary>Shows the files in File Explorer (the first one selected).</summary>
    void Reveal(IReadOnlyList<string> paths);
    /// <summary>What the platform offers for sending files (see <see cref="SaveActions.EmailRoute"/>).</summary>
    SendProbe SendProbe { get; }
    /// <summary>Opens the share window for the files.</summary>
    void Share(IReadOnlyList<string> paths, string title);
    /// <summary>Starts a mail message with the files attached; only when <see cref="SendProbe"/> says it can.</summary>
    void ComposeEmail(IReadOnlyList<string> paths);
    /// <summary>Puts the files (and the picture of a single image) on the clipboard.</summary>
    void Copy(ClipboardContent content);
}

/// <summary>
/// The Windows implementation. Email goes through the share window, which lists Mail and
/// Outlook: there is no direct "new message with attachment" route (Simple MAPI is not
/// used; the new Outlook does not support it).
/// </summary>
public sealed class WindowsFileActions : IFileActions
{
    private readonly Func<IntPtr> _ownerWindow;
    private readonly ShareService _share;

    /// <param name="ownerWindow">The window dialogs and the share window belong to (its HWND).</param>
    public WindowsFileActions(Func<IntPtr> ownerWindow)
    {
        _ownerWindow = ownerWindow;
        _share = new ShareService(ownerWindow);
    }

    public void Open(string path) => SavedFiles.Open(path);

    public void Reveal(IReadOnlyList<string> paths)
    {
        if (paths.Count > 0) SavedFiles.Reveal(paths[0]);
    }

    public SendProbe SendProbe => new(CanCompose: false, CanShare: ShareService.IsSupported);

    public void Share(IReadOnlyList<string> paths, string title) => _share.Share(paths, title);

    public void ComposeEmail(IReadOnlyList<string> paths) =>
        throw new NotSupportedException("Email goes through the share window on Windows.");

    public void OpenWith(string path)
    {
        var info = new OpenAsInfo
        {
            File = path,
            Class = null,
            // Run the chosen app; the dialog's "always use this app" box is the user's own choice.
            Flags = OaifAllowRegistration | OaifExec,
        };
        int result = SHOpenWithDialog(_ownerWindow(), ref info);
        if (result < 0 && result != HResultCancelled) Marshal.ThrowExceptionForHR(result);
    }

    public void Copy(ClipboardContent content)
    {
        var data = ClipboardData(content, LoadImage);
        // copy: true renders every format now, so the clipboard keeps them after the app exits.
        // WPF retries while another app holds the clipboard open, then throws.
        Clipboard.SetDataObject(data, copy: true);
    }

    /// <summary>
    /// The clipboard data for <paramref name="content"/>: the files as a file list (pasting into
    /// a folder copies them) and, for one image file, its picture.
    /// </summary>
    internal static DataObject ClipboardData(ClipboardContent content, Func<string, BitmapSource?> loadImage)
    {
        var data = new DataObject();
        var files = new StringCollection();
        foreach (string path in content.Files) files.Add(path);
        data.SetFileDropList(files);
        // DROPEFFECT_COPY: paste copies the files instead of moving them.
        data.SetData(PreferredDropEffect, new MemoryStream(BitConverter.GetBytes(DropEffectCopy)));
        if (content.ImageFile is { } image && loadImage(image) is { } picture) data.SetImage(picture);
        return data;
    }

    /// <summary>The picture of an image file, fully decoded so the file is not held open.</summary>
    internal static BitmapSource? LoadImage(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            var frame = decoder.Frames[0];
            frame.Freeze();
            return frame;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NotSupportedException
                                      or FileFormatException or ArgumentException or InvalidOperationException)
        {
            return null;
        }
    }

    internal const string PreferredDropEffect = "Preferred DropEffect";
    private const int DropEffectCopy = 1;

    private const int OaifAllowRegistration = 0x1;
    private const int OaifExec = 0x4;
    /// <summary>HRESULT_FROM_WIN32(ERROR_CANCELLED): the user closed the dialog.</summary>
    private const int HResultCancelled = unchecked((int)0x800704C7);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct OpenAsInfo
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string File;
        [MarshalAs(UnmanagedType.LPWStr)] public string? Class;
        public int Flags;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHOpenWithDialog(IntPtr hwndParent, ref OpenAsInfo info);
}

/// <summary>Turns a refused file action into a message for the user.</summary>
internal static class FileActionErrors
{
    public static string Describe(Exception e) => e switch
    {
        COMException { HResult: unchecked((int)0x800401D0) } => "The clipboard is in use by another app. Try again.",
        ExternalException when e.Message.Length > 0 => e.Message,
        Win32Exception win32 => win32.Message,
        _ => e.Message,
    };
}
