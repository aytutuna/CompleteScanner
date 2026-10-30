namespace LazyScan.Core;

// Port of Sources/CompleteScannerKit/Core/SaveActions.swift: what can be done with saved files
// (open, open with, show in folder, share, email, copy) and what happens on its own after a
// save. The platform carries the actions out; the choices are made here so both apps make
// the same ones.

/// <summary>
/// What happens on its own once a save has finished (<see cref="OutputOptions.AfterSave"/>).
/// <see cref="None"/> comes first: it is the default and the fallback for an action a newer
/// version adds. Add new members after the existing ones.
/// </summary>
public enum AfterSaveAction
{
    None,
    Open,
    Reveal,
    Share,
}

/// <summary>Something the user can do with saved files: the Saved tab's cards and the bar shown after a save.</summary>
public enum FileAction
{
    Open,
    OpenWith,
    Reveal,
    Share,
    Email,
    Copy,
}

/// <summary>The step an after-save action comes down to for the files just saved.</summary>
/// <param name="Action">What to do; never <see cref="AfterSaveAction.None"/>.</param>
/// <param name="Paths">The files to do it with, in the order they were saved.</param>
public sealed record SaveFollowUp(AfterSaveAction Action, IReadOnlyList<string> Paths)
{
    /// <summary>The file action that carries the step out.</summary>
    public FileAction FileAction => Action switch
    {
        AfterSaveAction.Open => FileAction.Open,
        AfterSaveAction.Share => FileAction.Share,
        _ => FileAction.Reveal,
    };

    public bool Equals(SaveFollowUp? other) =>
        other is not null && Action == other.Action && Paths.SequenceEqual(other.Paths);

    public override int GetHashCode() => HashCode.Combine(Action, Paths.Count);
}

/// <summary>What Copy puts on the clipboard.</summary>
/// <param name="Files">Every file, as files (pasting into a folder copies them).</param>
/// <param name="ImageFile">
/// The one image file whose picture is put on the clipboard too, so it can be pasted into a
/// document or an image editor; null for a PDF or several files.
/// </param>
public sealed record ClipboardContent(IReadOnlyList<string> Files, string? ImageFile)
{
    public bool Equals(ClipboardContent? other) =>
        other is not null && ImageFile == other.ImageFile && Files.SequenceEqual(other.Files);

    public override int GetHashCode() => HashCode.Combine(ImageFile, Files.Count);
}

/// <summary>How files are sent to another app or a person.</summary>
public enum SendRoute
{
    /// <summary>A new mail message with the files attached, in the user's mail app (nothing is sent until the user sends it).</summary>
    Compose,
    /// <summary>The system share window, where the user picks Mail, Outlook or another app.</summary>
    ShareSheet,
    /// <summary>Neither is available: the files are shown in their folder so they can be attached by hand.</summary>
    ShowInFolder,
}

/// <summary>What the platform can do to send files.</summary>
/// <param name="CanCompose">A mail message with the files attached can be started directly (macOS Mail).</param>
/// <param name="CanShare">The system share window is available.</param>
public sealed record SendProbe(bool CanCompose, bool CanShare);

public static class SaveActions
{
    /// <summary>Shown when the files are shown in their folder because they could not be shared.</summary>
    public const string ShowInFolderMessage =
        "Sharing is not available here, so the file is shown in its folder. Attach it from there.";

    private static readonly string[] ImageExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff"];

    /// <summary>
    /// The step <paramref name="action"/> comes down to for <paramref name="savedPaths"/>, the
    /// files a save wrote; null when there is nothing to do. The caller runs it only after a
    /// save that finished: not after one that was cancelled or failed part-way. Opening
    /// several files (a batch of photos) would start one viewer per file, so they are shown in
    /// their folder instead.
    /// </summary>
    public static SaveFollowUp? Plan(AfterSaveAction action, IReadOnlyList<string> savedPaths)
    {
        if (savedPaths.Count == 0) return null;
        return action switch
        {
            AfterSaveAction.Open when savedPaths.Count > 1 => new SaveFollowUp(AfterSaveAction.Reveal, [.. savedPaths]),
            AfterSaveAction.Open or AfterSaveAction.Reveal or AfterSaveAction.Share => new SaveFollowUp(action, [.. savedPaths]),
            _ => null,
        };
    }

    /// <summary>
    /// The actions offered for <paramref name="fileCount"/> saved files, in menu order. Open
    /// and Open with work on one file; showing, sharing, emailing and copying take several.
    /// </summary>
    public static IReadOnlyList<FileAction> Offered(int fileCount) => fileCount switch
    {
        <= 0 => [],
        1 => [FileAction.Open, FileAction.OpenWith, FileAction.Reveal, FileAction.Share, FileAction.Email, FileAction.Copy],
        _ => [FileAction.Reveal, FileAction.Share, FileAction.Email, FileAction.Copy],
    };

    /// <summary>A JPEG, PNG or TIFF file (by its extension, in any case).</summary>
    public static bool IsImageFile(string path) =>
        ImageExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>What Copy puts on the clipboard: the files, and the picture of a single image file.</summary>
    public static ClipboardContent ClipboardContentFor(IReadOnlyList<string> paths) =>
        new([.. paths], paths.Count == 1 && IsImageFile(paths[0]) ? paths[0] : null);

    /// <summary>
    /// How Email sends the files: a new message in the mail app when the platform can start one
    /// with attachments, otherwise the share window (it lists the mail apps), otherwise the
    /// folder. Nothing is ever sent without the user sending it.
    /// </summary>
    public static SendRoute EmailRoute(SendProbe probe) =>
        probe.CanCompose ? SendRoute.Compose
        : probe.CanShare ? SendRoute.ShareSheet
        : SendRoute.ShowInFolder;

    /// <summary>How Share sends the files: the share window, otherwise the folder.</summary>
    public static SendRoute ShareRoute(SendProbe probe) =>
        probe.CanShare ? SendRoute.ShareSheet : SendRoute.ShowInFolder;

    /// <summary>The title of the share window: the file's name, or "3 files".</summary>
    public static string ShareTitle(IReadOnlyList<string> paths) =>
        paths.Count == 1 ? Path.GetFileName(paths[0]) : $"{paths.Count} files";
}
