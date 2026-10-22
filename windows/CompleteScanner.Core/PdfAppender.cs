using System.Security.Cryptography;
using System.Text;

namespace CompleteScanner.Core;

// Twin of Sources/CompleteScannerKit/Output/PDFAppender.swift: the same update, byte for byte, with
// the same refusals and messages.

/// <summary>Why pages could not be added to a PDF (<see cref="PdfAppendException"/>).</summary>
public enum PdfAppendProblem
{
    /// <summary>The file is not a PDF.</summary>
    NotPdf,
    /// <summary>Its cross-reference data or page tree does not hold up.</summary>
    Damaged,
    /// <summary>It is password-protected (encrypted).</summary>
    Encrypted,
    /// <summary>It is laid out in a way the reader does not handle (bytes before the header, a filter other than Flate).</summary>
    Unsupported,
    /// <summary>It is read-only, or the user may not change it.</summary>
    ReadOnly,
    /// <summary>Another app has it open.</summary>
    InUse,
    /// <summary>It is no longer where it was picked.</summary>
    Missing,
    /// <summary>It changed while the pages were being added.</summary>
    Changed,
    /// <summary>The updated file did not read back as it should (the original stays as it was).</summary>
    NotVerified,
    /// <summary>The updated file could not be written next to it, say on a full disk (the original stays as it was).</summary>
    NotWritten,
    /// <summary>
    /// The original was moved aside to be replaced, the replacement failed and it could not be
    /// moved back: it is in its folder under the backup name the message gives (<see cref="PdfAppender.LeftAsBackupMessage"/>).
    /// </summary>
    LeftAsBackup,
}

/// <summary>Pages were not added; <see cref="Exception.Message"/> says why in words for the user.</summary>
public sealed class PdfAppendException(PdfAppendProblem problem, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public PdfAppendProblem Problem { get; } = problem;
}

/// <summary>A PDF pages are about to be added to, as read before anything is written (<see cref="PdfAppender.Inspect"/>).</summary>
/// <param name="Path">The file.</param>
/// <param name="PageCount">Its pages now.</param>
/// <param name="IsSigned">It carries a signature (<see cref="PdfReaderLite.IsSigned"/>).</param>
/// <param name="IsCertified">Its signature is a certification, which adding pages breaks (<see cref="PdfReaderLite.IsCertified"/>).</param>
/// <param name="PdfAPart">The PDF/A part it claims; null when it claims none.</param>
/// <param name="PdfAConformance">The PDF/A level it claims ("A", "B", "U"); null when none.</param>
/// <param name="KeepsPdfA">It claims PDF/A and the added pages keep it so (see <see cref="PdfAppender.KeepsPdfA"/>).</param>
public sealed record PdfAppendTarget(string Path, int PageCount, bool IsSigned, int? PdfAPart, string? PdfAConformance, bool KeepsPdfA,
                                     bool IsCertified = false)
{
    public bool IsPdfA => PdfAPart is not null;

    /// <summary>What the user should know before pages are added: the signature, a PDF/A level that may not be kept.</summary>
    public IReadOnlyList<string> Warnings
    {
        get
        {
            string name = System.IO.Path.GetFileName(Path);
            var warnings = new List<string>();
            if (IsCertified) warnings.Add(PdfAppender.CertifiedWarning(name));
            else if (IsSigned) warnings.Add(PdfAppender.SignedWarning(name));
            if (PdfAPart is { } part && !KeepsPdfA) warnings.Add(PdfAppender.PdfAWarning(name, part, PdfAConformance));
            return warnings;
        }
    }

    /// <summary>The question asked before adding pages despite <see cref="Warnings"/>; null when there are none.</summary>
    public string? ConfirmMessage => Warnings is { Count: > 0 } warnings
        ? string.Join("\n\n", warnings) + "\n\n" + PdfAppender.ConfirmQuestion
        : null;
}

/// <summary>Pages added to a file.</summary>
public sealed record PdfAppendResult(string Path, int PagesBefore, int PagesAdded, long Bytes)
{
    public int PageCount => PagesBefore + PagesAdded;
}

/// <summary>Fixed values for tests: the update's new file identifier.</summary>
public sealed record PdfAppendOptions
{
    /// <summary>The identifier's second half after the update (16 bytes); null: random.</summary>
    public byte[]? DocumentId { get; init; }
}

/// <summary>
/// Adds scanned pages to the end of an existing PDF as an incremental update (ISO 32000-1
/// 7.5.6): the original bytes stay exactly as they are, and after them come the new pages'
/// objects (written as <see cref="PdfBuilder"/> writes pages, with their image and text layer),
/// the page tree's root again with the new pages added to its /Kids and its /Count, and a
/// cross-reference section of the same kind as the file's newest one (a table, or an
/// uncompressed stream) whose trailer points back at the earlier one (/Prev).
/// <para>
/// The new pages hang off the root of the page tree and say their own /MediaBox, /Resources and
/// /Rotate 0 (and /CropBox, when the root has one), so nothing the root passes down to its pages
/// changes them. They use their own copy of the text layer's font.
/// </para>
/// <para>
/// Encrypted, damaged and unsupported files are refused (<see cref="PdfAppendException"/>). A
/// file is never changed in place: the original and the update are written to a hidden
/// temporary file next to it, which is read back (page count, the original bytes unchanged at
/// its start) before it replaces the original (ReplaceFile, keeping the original's permissions,
/// alternate data streams and encryption; other hard links to it keep the old content). Every failure is a <see cref="PdfAppendException"/>
/// whose message is for the user.
/// </para>
/// </summary>
public static class PdfAppender
{
    public const string ButtonLabel = "Add to existing PDF…";
    public const string ButtonHint = "Add the pages to the end of a PDF you choose";
    public const string SavedMenuLabel = "Add the scanned pages to this PDF";
    public const string SavedMenuHint = "Add the pages waiting to be saved to the end of this PDF";
    public const string PickerTitle = "Add the pages to which PDF?";
    public const string ConfirmQuestion = "Add the pages anyway?";

    /// <summary>The Save button while the queue goes into a picked PDF (the app's AppendTarget).</summary>
    public static string SaveTitle(string fileName) => $"Add to {fileName}";

    /// <summary>Said after adding pages while Protect with a password is on: the file decides, and it has none.</summary>
    public const string NoPasswordNote = "The file has no password, so the added pages have none either.";

    /// <summary>Why pages could not be added to <paramref name="fileName"/>.</summary>
    public static string Message(PdfAppendProblem problem, string fileName) => problem switch
    {
        PdfAppendProblem.NotPdf => $"{fileName} is not a PDF, so pages can't be added to it.",
        PdfAppendProblem.Damaged => $"{fileName} looks damaged, so pages can't be added to it safely. Save them as a new PDF instead.",
        PdfAppendProblem.Encrypted => $"{fileName} is password-protected, so pages can't be added to it. Save them as a new PDF instead.",
        PdfAppendProblem.Unsupported => $"{fileName} is laid out in a way pages can't be added to here. Save them as a new PDF instead.",
        PdfAppendProblem.ReadOnly => $"{fileName} can't be changed: it is read-only, or you don't have permission to change it.",
        PdfAppendProblem.InUse => $"{fileName} is open in another app. Close it there, then add the pages again.",
        PdfAppendProblem.Missing => $"{fileName} is no longer in its folder. It may have been moved, renamed or deleted.",
        PdfAppendProblem.Changed => $"{fileName} was changed by another app while the pages were being added, so it was left as it was. Try again.",
        PdfAppendProblem.NotWritten => $"The pages could not be added to {fileName}: the updated file could not be written in its folder (the disk may be full), so the original was left as it was.",
        PdfAppendProblem.LeftAsBackup => LeftAsBackupMessage(fileName, null),
        _ =>$"The pages could not be added to {fileName}: the updated file did not check out, so the original was left as it was.",
    };

    /// <summary>
    /// For <see cref="PdfAppendProblem.LeftAsBackup"/>: where the unchanged file is now, so the user
    /// can find it (<paramref name="backupName"/>, the backup's file name; null: not known).
    /// </summary>
    public static string LeftAsBackupMessage(string fileName, string? backupName) =>
        $"The pages could not be added to {fileName}, and the file could not be put back under its name. It is unchanged, in the same folder, "
        + (backupName is null ? "under a name ending in .pdf.bak" : $"named {backupName}")
        + $". Rename it back to {fileName}, then add the pages again.";

    public static string SignedWarning(string fileName) =>
        $"{fileName} is signed. Adding pages keeps the signature, but PDF apps will show that the file was changed after it was signed.";

    /// <summary>For a certified file (<see cref="PdfReaderLite.IsCertified"/>): no certification allows adding pages.</summary>
    public static string CertifiedWarning(string fileName) =>
        $"{fileName} is certified. Its certification does not allow adding pages, so PDF apps will show the certification as no longer valid.";

    public static string PdfAWarning(string fileName, int part, string? conformance) =>
        $"{fileName} is a PDF/A-{part}{conformance?.ToLowerInvariant()} file. The added pages may not meet that standard, so it may no longer pass as PDF/A.";

    /// <summary>"Added 2 pages to Contract.pdf (now 11 pages, 1.4 MB)", as a save says "Saved …".</summary>
    public static string AddedMessage(int added, string fileName, int pageCount, string? size) =>
        $"Added {added} {(added == 1 ? "page" : "pages")} to {fileName} (now {pageCount} {(pageCount == 1 ? "page" : "pages")}{(size is null ? "" : ", " + size)})";

    /// <summary>
    /// The added pages keep the file's PDF/A claim when it is part 1, 2 or 3 at level B or U
    /// (level A also asks for a structure the new pages do not have) and its output intent is
    /// RGB, which covers the pages' color images; their font is embedded, and the update keeps the
    /// file identifier, the metadata and the document information as they were.
    /// </summary>
    public static bool KeepsPdfA(int? part, string? conformance, int? outputIntentComponents) =>
        outputIntentComponents == 3 && (part, conformance) is (1, "B") or (2 or 3, "B" or "U");

    /// <summary>Reads what adding pages to <paramref name="path"/> means, checking it can be changed; throws <see cref="PdfAppendException"/>.</summary>
    public static PdfAppendTarget Inspect(string path)
    {
        string full = System.IO.Path.GetFullPath(path);
        using var stream = OpenForUpdate(full);
        using var reader = Read(stream, full);
        return Describe(reader, full);
    }

    internal static PdfAppendTarget Describe(PdfReaderLite reader, string path)
    {
        if (reader.IsEncrypted) throw Refusal(PdfAppendProblem.Encrypted, path);
        // The signature and the output intent are read now, from objects the page tree did not need.
        return Mapped(path, () =>
        {
            int? part = reader.PdfAPart;
            string? conformance = reader.PdfAConformance;
            return new PdfAppendTarget(path, reader.PageCount, reader.IsSigned, part, conformance,
                                       part is not null && KeepsPdfA(part, conformance, reader.OutputIntentComponents),
                                       reader.IsCertified);
        });
    }

    /// <summary>The original with <paramref name="pages"/> added, in memory.</summary>
    public static byte[] Append(byte[] original, IReadOnlyList<PdfPageInput> pages, PdfAppendOptions? options = null)
    {
        var reader = new PdfReaderLite(original);
        if (reader.IsEncrypted) throw new PdfReadException(PdfReadProblem.Encrypted, "The file is encrypted.");
        using var output = new MemoryStream();
        output.Write(original);
        WriteUpdate(reader, output, pages, options);
        return output.ToArray();
    }

    /// <summary>
    /// Writes the update for <paramref name="pages"/> to <paramref name="output"/>, which already
    /// holds the file <paramref name="reader"/> read (positioned at its end). Starts with an end
    /// of line when the file does not end with one.
    /// </summary>
    public static void WriteUpdate(PdfReaderLite reader, Stream output, IReadOnlyList<PdfPageInput> pages,
                                   PdfAppendOptions? options = null, Action<string>? progress = null,
                                   CancellationToken cancellationToken = default)
    {
        if (pages.Count == 0) throw new ArgumentException("There are no pages to add.", nameof(pages));
        if (reader.IsEncrypted) throw new PdfReadException(PdfReadProblem.Encrypted, "The file is encrypted.");
        var root = reader.PagesRoot!;
        var rootDictionary = reader.PagesRootDictionary!;
        if (reader.Resolve(rootDictionary["Kids"]) is not PdfArray oldKids) throw PdfReadException.Damaged("The page tree's root has no /Kids.");

        bool hasText = pages.Any(p => p.OcrLines is { Count: > 0 });

        // Every new object, and an update's cross-reference stream, within PDF's object numbers.
        long lastObject = reader.NextObjectNumber + (hasText ? 6L : 0L) + pages.Count * 3L - 1 + (reader.XrefIsStream ? 1 : 0);
        if (lastObject > PdfReaderLite.MaxObjectNumber)
        {
            throw new PdfReadException(PdfReadProblem.Unsupported, "The file has no object numbers left for the new pages.");
        }

        long position = reader.Length;
        if (reader.ByteAt(position - 1) is not (10 or 13))
        {
            output.WriteByte((byte)'\n');
            position++;
        }
        var w = new PdfObjectWriter(output, position);
        var codes = GlyphlessCodes.For(pages.SelectMany(p => p.OcrLines ?? []).Select(l => l.Text ?? ""));
        int next = reader.NextObjectNumber;
        int fontObject = hasText ? next : 0;
        if (hasText) next += 6;
        int firstPage = next;
        next += pages.Count * 3;

        int rootGeneration = reader.GenerationOf(root.Number);
        string parent = $"{root.Number} {rootGeneration} R";
        bool rootHasCropBox = rootDictionary.ContainsKey("CropBox");

        if (hasText) PdfBuilder.WriteTextFont(w, fontObject, codes);
        var kids = new List<PdfObject>(oldKids.Items);
        for (int i = 0; i < pages.Count; i++)
        {
            if (cancellationToken.IsCancellationRequested) throw ScanException.Cancelled();
            progress?.Invoke($"Adding page {i + 1} of {pages.Count}…");
            var page = pages[i];
            string extra = " /Rotate 0";
            if (rootHasCropBox)
            {
                double dpi = Math.Max(page.Dpi, 1);
                extra += $" /CropBox [0 0 {PdfBuilder.F(page.PixelWidth / dpi * 72.0)} {PdfBuilder.F(page.PixelHeight / dpi * 72.0)}]";
            }
            int pageObject = firstPage + i * 3;
            PdfBuilder.WritePage(w, pageObject, pageObject + 1, pageObject + 2, parent, i, page, fontObject, codes, extra);
            kids.Add(new PdfReference(pageObject, 0));
        }

        // The root again: its kids end with the new pages, its count says every page under it.
        var updatedRoot = rootDictionary.Copy();
        updatedRoot["Kids"] = new PdfArray(kids);
        updatedRoot["Count"] = new PdfNumber(reader.PageCount + pages.Count);
        w.WriteObject(root.Number, rootGeneration, updatedRoot.ToString());

        byte[] newId = options?.DocumentId is { Length: 16 } given ? given : RandomNumberGenerator.GetBytes(16);
        string firstId = reader.Resolve(reader.Trailer["ID"]) is PdfArray { Items.Count: >= 1 } ids && reader.Resolve(ids.Items[0]) is PdfString original
            ? Convert.ToHexString(original.Bytes)
            : Convert.ToHexString(newId);
        var trailer = new StringBuilder();
        trailer.Append(" /Root ");
        reader.Root!.WriteTo(trailer);
        if (reader.Trailer["Info"] is { } info and not PdfNull and not PdfStream)
        {
            trailer.Append(" /Info ");
            info.WriteTo(trailer);
        }
        trailer.Append($" /ID [<{firstId}> <{Convert.ToHexString(newId)}>] /Prev {reader.StartXref}");

        if (reader.XrefIsStream)
        {
            int xrefObject = next;
            w.FinishUpdateStream(xrefObject, $"/Size {xrefObject + 1}{trailer}");
        }
        else
        {
            w.FinishUpdate($"/Size {next}{trailer}");
        }
    }

    /// <summary>
    /// Adds <paramref name="pages"/> to the end of the PDF at <paramref name="path"/>. The file is
    /// held open (others may read it, not change it) while the original and the update are
    /// written to a hidden temporary file in its folder; that file is read back and must have the
    /// original's bytes at its start, an update pointing back at the original's last section and
    /// every page; then it takes the original's place (<see cref="ReplaceOriginal"/>), keeping what
    /// belongs to the file rather than to its bytes. Any failure leaves the original as it was
    /// (under its backup name in the one case <see cref="PdfAppendProblem.LeftAsBackup"/> says),
    /// removes the temporary file and is a <see cref="PdfAppendException"/>.
    /// </summary>
    public static PdfAppendResult AppendToFile(string path, IReadOnlyList<PdfPageInput> pages,
                                               Action<string>? progress = null,
                                               CancellationToken cancellationToken = default,
                                               PdfAppendOptions? options = null)
    {
        if (pages.Count == 0) throw new ArgumentException("There are no pages to add.", nameof(pages));
        string full = System.IO.Path.GetFullPath(path);
        string directory = System.IO.Path.GetDirectoryName(full)!;
        string tmp = System.IO.Path.Combine(directory, $".{Guid.NewGuid()}.pdf.tmp");
        var original = OpenForUpdate(full);
        PdfReaderLite? reader = null;
        try
        {
            reader = Read(original, full);
            var target = Describe(reader, full);
            long length = original.Length;
            var written = File.GetLastWriteTimeUtc(full);
            var created = File.GetCreationTimeUtc(full);
            var attributes = File.GetAttributes(full);
            long previousXref = reader.StartXref;
            int sections = reader.SectionCount;
            byte[] originalHash = WriteTemporary(tmp, original, length, reader, pages, options, progress, cancellationToken, full);
            Verify(tmp, length, originalHash, target.PageCount + pages.Count, previousXref, sections + 1, full);

            reader.Dispose();
            reader = null;
            original.Dispose();
            // Nobody could write to it while it was held; it must still be the file that was read.
            if (new FileInfo(full) is not { Exists: true } now || now.Length != length || now.LastWriteTimeUtc != written)
            {
                throw Refusal(PdfAppendProblem.Changed, full);
            }
            PdfBuilder.SetHidden(tmp, false);
            try
            {
                File.SetCreationTimeUtc(tmp, created);
                File.SetAttributes(tmp, attributes == 0 ? FileAttributes.Normal : attributes);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Cosmetic: the pages are what matters.
            }
            ReplaceOriginal(tmp, full);
            return new PdfAppendResult(full, target.PageCount, pages.Count, new FileInfo(full).Length);
        }
        catch
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw;
        }
        finally
        {
            reader?.Dispose();
            original.Dispose();
        }
    }

    /// <summary>
    /// Opens the file for reading in a way that also checks it can be replaced: write access
    /// (refused for a read-only file), others may only read it meanwhile (refused while another
    /// app has it open to write, as PDF editors do).
    /// </summary>
    private static FileStream OpenForUpdate(string path)
    {
        try
        {
            return new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            throw Refusal(PdfAppendProblem.Missing, path, e);
        }
        catch (UnauthorizedAccessException e)
        {
            throw Refusal(PdfAppendProblem.ReadOnly, path, e);
        }
        catch (IOException e) when ((e.HResult & 0xFFFF) is 32 or 33) // sharing or lock violation
        {
            throw Refusal(PdfAppendProblem.InUse, path, e);
        }
    }

    private static PdfReaderLite Read(Stream stream, string path) => Mapped(path, () => new PdfReaderLite(stream, leaveOpen: true));

    /// <summary>
    /// <paramref name="read"/>, with what the reader finds wrong (it reads objects when they are
    /// first asked for, not only when it opens the file) as a refusal in words for the user.
    /// </summary>
    private static T Mapped<T>(string path, Func<T> read)
    {
        try
        {
            return read();
        }
        catch (PdfReadException e)
        {
            throw Refusal(ProblemOf(e.Problem), path, e);
        }
        catch (EndOfStreamException e)
        {
            throw Refusal(PdfAppendProblem.Damaged, path, e);
        }
    }

    /// <summary>
    /// The original and the update, written to the new hidden file <paramref name="tmp"/>; returns
    /// the original's SHA-256. A folder the user may not create files in is ReadOnly, a write that
    /// fails (a full disk) NotWritten, and what the reader finds wrong while writing as when reading.
    /// </summary>
    private static byte[] WriteTemporary(string tmp, Stream original, long length, PdfReaderLite reader,
                                         IReadOnlyList<PdfPageInput> pages, PdfAppendOptions? options,
                                         Action<string>? progress, CancellationToken cancellationToken, string path)
    {
        try
        {
            using var output = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            PdfBuilder.SetHidden(tmp, true);
            original.Position = 0;
            byte[] hash = CopyHashing(original, output, length, cancellationToken);
            WriteUpdate(reader, output, pages, options, progress, cancellationToken);
            output.Flush(flushToDisk: true);
            return hash;
        }
        catch (UnauthorizedAccessException e)
        {
            throw Refusal(PdfAppendProblem.ReadOnly, path, e);
        }
        catch (PdfReadException e)
        {
            throw Refusal(ProblemOf(e.Problem), path, e);
        }
        catch (EndOfStreamException e)
        {
            throw Refusal(PdfAppendProblem.Damaged, path, e);
        }
        catch (IOException e)
        {
            throw Refusal(PdfAppendProblem.NotWritten, path, e);
        }
    }

    /// <summary>
    /// The checked temporary file takes the original's place with ReplaceFile, which keeps what
    /// belongs to the original file rather than to its bytes: its permissions, its alternate data
    /// streams (the Zone.Identifier mark a downloaded file carries), EFS encryption, compression
    /// and creation time (not other hard links to it: they keep the old content). The original is
    /// moved aside under a backup name in the same folder meanwhile (with its own attributes, so
    /// visible unless it was hidden) and removed after; when it cannot be removed it is hidden and
    /// left. When the new file then cannot take the name, the original is moved back; if that also
    /// fails it stays under the backup name, which the refusal gives (LeftAsBackup). Where the file
    /// system has no ReplaceFile, one rename over the original (the creation time and attributes
    /// were copied to the temporary file before).
    /// </summary>
    private static void ReplaceOriginal(string tmp, string path)
    {
        string backup = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path)!, $".{Guid.NewGuid()}.pdf.bak");
        try
        {
            File.Replace(tmp, path, backup, ignoreMetadataErrors: true);
        }
        catch (FileNotFoundException e)
        {
            throw Refusal(PdfAppendProblem.Missing, path, e);
        }
        catch (IOException e) when (Win32Error(e) is 1 or 50 or 87) // invalid function, not supported, invalid parameter
        {
            Rename(tmp, path);
            return;
        }
        catch (IOException e) when (Win32Error(e) == 1177 && !File.Exists(path) && File.Exists(backup))
        {
            // The original was moved aside, but the new file could not take its name.
            throw PutBack(backup, path, e);
        }
        catch (UnauthorizedAccessException e)
        {
            throw Refusal(PdfAppendProblem.ReadOnly, path, e);
        }
        catch (IOException e)
        {
            throw Refusal(PdfAppendProblem.InUse, path, e);
        }
        try
        {
            File.Delete(backup);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            PdfBuilder.SetHidden(backup, true);
        }
    }

    /// <summary>
    /// The original, moved aside to <paramref name="backup"/> by a replacement that then failed
    /// (<paramref name="cause"/>), goes back to <paramref name="path"/>; returns the refusal to
    /// throw: InUse when it is back, LeftAsBackup naming the backup when it could not be moved.
    /// </summary>
    internal static PdfAppendException PutBack(string backup, string path, IOException cause)
    {
        try
        {
            File.Move(backup, path);
            return Refusal(PdfAppendProblem.InUse, path, cause);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            string fileName = System.IO.Path.GetFileName(path);
            return new PdfAppendException(PdfAppendProblem.LeftAsBackup,
                                          LeftAsBackupMessage(fileName, System.IO.Path.GetFileName(backup)), cause);
        }
    }

    private static void Rename(string tmp, string path)
    {
        try
        {
            File.Move(tmp, path, overwrite: true);
        }
        catch (UnauthorizedAccessException e)
        {
            throw Refusal(PdfAppendProblem.ReadOnly, path, e);
        }
        catch (IOException e)
        {
            throw Refusal(PdfAppendProblem.InUse, path, e);
        }
    }

    /// <summary>The Windows error code an <see cref="IOException"/> carries in its HRESULT.</summary>
    private static int Win32Error(IOException e) => e.HResult & 0xFFFF;

    private static PdfAppendProblem ProblemOf(PdfReadProblem problem) => problem switch
    {
        PdfReadProblem.NotPdf => PdfAppendProblem.NotPdf,
        PdfReadProblem.Encrypted => PdfAppendProblem.Encrypted,
        PdfReadProblem.Unsupported => PdfAppendProblem.Unsupported,
        _ => PdfAppendProblem.Damaged,
    };

    private static PdfAppendException Refusal(PdfAppendProblem problem, string path, Exception? inner = null) =>
        new(problem, Message(problem, System.IO.Path.GetFileName(path)), inner);

    private static byte[] CopyHashing(Stream from, Stream to, long length, CancellationToken cancellationToken)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[1 << 16];
        long left = length;
        while (left > 0)
        {
            if (cancellationToken.IsCancellationRequested) throw ScanException.Cancelled();
            int read = from.Read(buffer, 0, (int)Math.Min(buffer.Length, left));
            if (read == 0) throw new EndOfStreamException();
            hash.AppendData(buffer, 0, read);
            to.Write(buffer, 0, read);
            left -= read;
        }
        return hash.GetHashAndReset();
    }

    /// <summary>The temporary file read back: the original's bytes first, then an update with every page.</summary>
    private static void Verify(string tmp, long originalLength, byte[] originalHash, int pageCount, long previousXref, int sections, string path)
    {
        try
        {
            using var stream = new FileStream(tmp, FileMode.Open, FileAccess.Read, FileShare.Read);
            var prefix = new byte[1 << 16];
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long left = originalLength;
            while (left > 0)
            {
                int read = stream.Read(prefix, 0, (int)Math.Min(prefix.Length, left));
                if (read == 0) throw Refusal(PdfAppendProblem.NotVerified, path);
                hash.AppendData(prefix, 0, read);
                left -= read;
            }
            stream.Position = 0;
            using var check = new PdfReaderLite(stream, leaveOpen: true);
            bool ok = hash.GetHashAndReset().AsSpan().SequenceEqual(originalHash)
                      && !check.IsEncrypted
                      && check.PageCount == pageCount
                      && check.SectionCount == sections
                      && check.StartXref > originalLength
                      && check.LatestPrev == previousXref;
            if (!ok) throw Refusal(PdfAppendProblem.NotVerified, path);
        }
        catch (Exception e) when (e is PdfReadException or IOException)
        {
            throw Refusal(PdfAppendProblem.NotVerified, path, e);
        }
    }
}
