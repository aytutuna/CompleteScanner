using System.Text.Json.Serialization;

namespace CompleteScanner.Core;

// Port of Sources/CompleteScannerKit/Core/Models.swift. Enums serialize as camelCase
// strings (see StoreFiles.JsonOptions in Persistence.cs) matching the Swift rawValues, so
// settings/preset files stay conceptually interchangeable. Settings files load across
// versions (CONTRACTS.md, rule 6): every persisted property needs an initializer default,
// and the first member of every persisted enum is its default; add new members after the
// existing ones and never rename one.

// MARK: - Core enums

public enum ScanIntent
{
    Document,
    Photo,
}

public enum ColorMode
{
    Color,
    Grayscale,
    BlackWhite,
}

public enum ScanSource
{
    Flatbed,
    DocumentFeeder,
}

/// <summary>
/// What a save writes. <see cref="Text"/> and <see cref="Word"/> hold the recognized text of the
/// pages instead of their pictures (<see cref="TextExport"/>, <see cref="DocxWriter"/>); which
/// formats a mode offers and what each save does with a format are in <see cref="OutputFormats"/>.
/// </summary>
public enum OutputFormat
{
    Pdf,
    Jpeg,
    Png,
    Tiff,
    Text,
    Word,
}

/// <summary>
/// How small saved PDFs are made (see <see cref="PdfImageEncoding"/>). <see cref="Standard"/>
/// comes first because it is the default for everyone, including settings files written before
/// the setting existed, and the fallback for a size a newer version adds: it neither bloats a
/// file nor drops quality much. The start screen and the inspector show the sizes in
/// <see cref="PdfSizePresets.DisplayOrder"/> (largest first) instead.
/// </summary>
public enum PdfSizePreset
{
    Standard,
    Best,
    Compact,
    Smallest,
}

/// <summary>
/// Which sides of each sheet a feeder scan captures (<see cref="ScanSettings.Duplex"/>). Only
/// the document feeder scans two-sided; on the flatbed the setting is ignored. See
/// <see cref="DocumentSides"/>.
/// </summary>
public enum DuplexMode
{
    /// <summary>The front of each sheet only.</summary>
    Off,
    /// <summary>Both sides in one pass, by a feeder that can.</summary>
    Both,
    /// <summary>Both sides by hand: the fronts are scanned, the stack is turned over, then the backs are scanned.</summary>
    Manual,
}

/// <summary>
/// Along which edge the back sides are turned (<see cref="ScanSettings.BackBinding"/>): the long
/// edge, like the pages of a book (backs come out upright), or the short edge, like a wall
/// calendar (backs come out upside down and are turned upright).
/// </summary>
public enum DuplexBinding
{
    LongEdge,
    ShortEdge,
}

/// <summary>
/// How much may be on a page for it to count as blank (<see cref="DocumentOptions.BlankSensitivity"/>,
/// <see cref="BlankPageDetector"/>): <see cref="Low"/> only (next to) empty pages, <see cref="High"/>
/// also pages with a few marks. <see cref="Medium"/> comes first: it is the default and the
/// fallback for a level a newer version adds. Shown in <see cref="BlankSensitivities.DisplayOrder"/>.
/// </summary>
public enum BlankSensitivity
{
    Medium,
    Low,
    High,
}

/// <summary>
/// The user's say over whether a queued page is saved (<see cref="ScannedPage.Inclusion"/>):
/// <see cref="Automatic"/> follows the blank-page setting (<see cref="PageFilter.IsExcluded"/>);
/// <see cref="Keep"/> and <see cref="Skip"/> are one click on the page, whatever the setting.
/// Not stored in settings files.
/// </summary>
public enum PageInclusion
{
    Automatic,
    Keep,
    Skip,
}

/// <summary>
/// The app's color scheme: follow Windows, or force light or dark. An app preference, kept
/// apart from <see cref="ScanSettings"/> so that applying a preset never changes it.
/// </summary>
public enum AppAppearance
{
    System,
    Light,
    Dark,
}

public static class ModelLabels
{
    public static string Label(this ScanIntent intent) => intent switch
    {
        ScanIntent.Document => "Document",
        ScanIntent.Photo => "Photos",
        _ => intent.ToString(),
    };

    public static string Label(this ColorMode mode) => mode switch
    {
        ColorMode.Color => "Color",
        ColorMode.Grayscale => "Grayscale",
        ColorMode.BlackWhite => "Black & White",
        _ => mode.ToString(),
    };

    public static string Label(this ScanSource source) => source switch
    {
        ScanSource.Flatbed => "Flatbed",
        ScanSource.DocumentFeeder => "Document Feeder (ADF)",
        _ => source.ToString(),
    };

    public static string Label(this OutputFormat format) => format switch
    {
        OutputFormat.Pdf => "PDF",
        OutputFormat.Jpeg => "JPEG",
        OutputFormat.Png => "PNG",
        OutputFormat.Tiff => "TIFF",
        OutputFormat.Text => "Text (.txt)",
        OutputFormat.Word => "Word (.docx)",
        _ => format.ToString(),
    };

    public static string Label(this PdfSizePreset preset) => preset switch
    {
        PdfSizePreset.Standard => "Standard",
        PdfSizePreset.Best => "Best",
        PdfSizePreset.Compact => "Compact",
        PdfSizePreset.Smallest => "Smallest",
        _ => preset.ToString(),
    };

    /// <summary>One line saying what the size does, shown under the size picker.</summary>
    public static string Hint(this PdfSizePreset preset) => preset switch
    {
        PdfSizePreset.Standard => "Up to 300 dpi, gray pages saved in gray. For most documents.",
        PdfSizePreset.Best => "Full resolution, high quality. Largest files.",
        PdfSizePreset.Compact => "Up to 200 dpi, more compression. For email and uploads.",
        PdfSizePreset.Smallest => "Up to 150 dpi, most compression. For strict size limits.",
        _ => "",
    };

    public static string Label(this AfterSaveAction action) => action switch
    {
        AfterSaveAction.None => "Do nothing",
        AfterSaveAction.Open => "Open",
        AfterSaveAction.Reveal => "Show in folder",
        AfterSaveAction.Share => "Share…",
        _ => action.ToString(),
    };

    /// <summary>One line saying what the after-save action does, shown as its tooltip.</summary>
    public static string Hint(this AfterSaveAction action) => action switch
    {
        AfterSaveAction.None => "Stay in the app after saving.",
        AfterSaveAction.Open => "Open the saved file in its app. Several files are shown in their folder instead.",
        AfterSaveAction.Reveal => "Show the saved files in their folder.",
        AfterSaveAction.Share => "Open the share window to email the saved files or send them to an app.",
        _ => "",
    };

    public static string Label(this DuplexMode mode) => mode switch
    {
        DuplexMode.Off => "One side",
        DuplexMode.Both => "Both sides",
        DuplexMode.Manual => "Both sides, turned by hand",
        _ => mode.ToString(),
    };

    /// <summary>One line saying what the choice does, shown under the sides picker.</summary>
    public static string Hint(this DuplexMode mode) => mode switch
    {
        DuplexMode.Off => "Only the front of each sheet is scanned.",
        DuplexMode.Both => "The feeder scans both sides of every sheet in one pass.",
        DuplexMode.Manual => "Scan the fronts, turn the stack over, then scan the backs. The pages are put in order.",
        _ => "",
    };

    public static string Label(this DuplexBinding binding) => binding switch
    {
        DuplexBinding.LongEdge => "Long edge (like a book)",
        DuplexBinding.ShortEdge => "Short edge (like a calendar)",
        _ => binding.ToString(),
    };

    public static string Label(this BlankSensitivity sensitivity) => sensitivity switch
    {
        BlankSensitivity.Low => "Low",
        BlankSensitivity.Medium => "Medium",
        BlankSensitivity.High => "High",
        _ => sensitivity.ToString(),
    };

    /// <summary>One line saying what counts as blank at that level, shown under the picker.</summary>
    public static string Hint(this BlankSensitivity sensitivity) => sensitivity switch
    {
        BlankSensitivity.Low => "Only pages with nothing on them count as blank.",
        BlankSensitivity.Medium => "Empty pages count as blank, also with dust, show-through or a lone page number.",
        BlankSensitivity.High => "Pages with a few small marks count as blank too. Check the flagged pages before saving.",
        _ => "",
    };

    public static string Label(this FileAction action) => action switch
    {
        FileAction.Open => "Open",
        FileAction.OpenWith => "Open with…",
        FileAction.Reveal => "Show in folder",
        FileAction.Share => "Share…",
        FileAction.Email => "Email…",
        FileAction.Copy => "Copy",
        _ => action.ToString(),
    };

    public static string FileExtension(this OutputFormat format) => format switch
    {
        OutputFormat.Pdf => "pdf",
        OutputFormat.Jpeg => "jpg",
        OutputFormat.Png => "png",
        OutputFormat.Tiff => "tiff",
        OutputFormat.Text => "txt",
        OutputFormat.Word => "docx",
        _ => format.ToString().ToLowerInvariant(),
    };
}

/// <summary>
/// Which formats each mode offers and what each save writes for a format. Twin of the
/// <c>OutputFormat</c> members in Sources/CompleteScannerKit/Core/Models.swift.
/// </summary>
public static class OutputFormats
{
    /// <summary>JPEG, PNG and TIFF: a picture of each page. Photos are saved in these only.</summary>
    public static bool IsImageFormat(this OutputFormat format) =>
        format is OutputFormat.Jpeg or OutputFormat.Png or OutputFormat.Tiff;

    /// <summary>Text and Word: the recognized text of the pages, read by OCR when the file is saved.</summary>
    public static bool IsTextFormat(this OutputFormat format) =>
        format is OutputFormat.Text or OutputFormat.Word;

    /// <summary>
    /// The formats the inspector offers: every format for documents, the image formats for
    /// photos (a photo has no text to save, and PDF photos are saved as JPEG).
    /// </summary>
    public static IReadOnlyList<OutputFormat> Offered(ScanIntent intent) =>
        intent == ScanIntent.Photo
            ? [OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Tiff]
            : [OutputFormat.Pdf, OutputFormat.Word, OutputFormat.Text, OutputFormat.Jpeg, OutputFormat.Png, OutputFormat.Tiff];

    /// <summary>The format a photo is saved in: <paramref name="format"/> when it is an image format, otherwise JPEG.</summary>
    public static OutputFormat ImageFormatOrJpeg(OutputFormat format) =>
        format.IsImageFormat() ? format : OutputFormat.Jpeg;

    /// <summary>
    /// The format the collected pages are saved in together: Text and Word as chosen, anything
    /// else as one PDF (the image formats apply to scans saved one at a time).
    /// </summary>
    public static OutputFormat QueueFormat(OutputFormat format) =>
        format.IsTextFormat() ? format : OutputFormat.Pdf;

    /// <summary>
    /// Whether a save writes a PDF: the collected pages in any format but Text and Word, a scan
    /// saved at once only in PDF. The text beside a PDF can be asked for then.
    /// </summary>
    public static bool SavesPdf(OutputFormat format, bool collectsPages) =>
        collectsPages ? QueueFormat(format) == OutputFormat.Pdf : format == OutputFormat.Pdf;

    /// <summary>The format of a page made of a scan, like the ID card's: PDF or the image format chosen; PDF for the text formats.</summary>
    public static OutputFormat PageFormat(OutputFormat format) =>
        format.IsImageFormat() ? format : OutputFormat.Pdf;

    /// <summary>"Save PDF", "Save Word", "Save Text": the button that saves the collected pages.</summary>
    public static string SaveTitle(OutputFormat format) => QueueFormat(format) switch
    {
        OutputFormat.Word => "Save Word",
        OutputFormat.Text => "Save Text",
        _ => "Save PDF",
    };

    /// <summary>"Save PDF (3 pages)", or just the <see cref="SaveTitle"/> when no page would be saved.</summary>
    public static string SaveTitle(OutputFormat format, int pageCount) =>
        pageCount > 0 ? $"{SaveTitle(format)} ({pageCount} page{(pageCount == 1 ? "" : "s")})" : SaveTitle(format);
}

// MARK: - Settings

public sealed class AdjustmentSettings : IEquatable<AdjustmentSettings>
{
    public bool AutoEnhance { get; set; } = false;
    /// <summary>-1 ... 1, neutral 0</summary>
    public double Brightness { get; set; } = 0.0;
    /// <summary>0.25 ... 4, neutral 1</summary>
    public double Contrast { get; set; } = 1.0;
    /// <summary>0 ... 2, neutral 1</summary>
    public double Saturation { get; set; } = 1.0;
    /// <summary>-2 ... 2, neutral 0; positive sharpens, negative softens (Gaussian blur)</summary>
    public double Sharpness { get; set; } = 0.0;
    /// <summary>Reduce moiré from scanning printed material.</summary>
    public bool Descreen { get; set; } = false;
    /// <summary>Boost faded colors of old photos.</summary>
    public bool RestoreFadedColors { get; set; } = false;
    /// <summary>0 ... 1 luminance threshold used for ColorMode.BlackWhite conversion.</summary>
    public double BlackWhiteThreshold { get; set; } = 0.5;

    [JsonIgnore]
    public bool IsIdentity =>
        !AutoEnhance && Brightness == 0 && Contrast == 1 && Saturation == 1
            && Sharpness == 0 && !Descreen && !RestoreFadedColors;

    public AdjustmentSettings Clone() => (AdjustmentSettings)MemberwiseClone();

    public bool Equals(AdjustmentSettings? other) =>
        other is not null
        && AutoEnhance == other.AutoEnhance && Brightness == other.Brightness
        && Contrast == other.Contrast && Saturation == other.Saturation
        && Sharpness == other.Sharpness && Descreen == other.Descreen
        && RestoreFadedColors == other.RestoreFadedColors
        && BlackWhiteThreshold == other.BlackWhiteThreshold;

    public override bool Equals(object? obj) => Equals(obj as AdjustmentSettings);
    public override int GetHashCode() =>
        HashCode.Combine(AutoEnhance, Brightness, Contrast, Saturation,
                         Sharpness, Descreen, RestoreFadedColors, BlackWhiteThreshold);
}

/// <summary>
/// Settings for the saved files themselves, kept together as <see cref="ScanSettings.Output"/>
/// (the "output" object in settings files): the PDF size, the after-save action and the text
/// file beside a PDF. Later output features add their fields here.
/// </summary>
public sealed class OutputOptions : IEquatable<OutputOptions>
{
    /// <summary>How small saved PDFs are made. Settings without it get Standard.</summary>
    public PdfSizePreset PdfSize { get; set; } = PdfSizePreset.Standard;

    /// <summary>
    /// What happens on its own after a save (see <see cref="SaveActions.Plan"/>). Settings
    /// without it, or with an action this version does not know, get None.
    /// </summary>
    public AfterSaveAction AfterSave { get; set; } = AfterSaveAction.None;

    /// <summary>
    /// A saved PDF gets a text file beside it with the same name (<see cref="TextExport"/>): the
    /// recognized text of its pages, read once for both. Settings without it get false.
    /// </summary>
    public bool AlsoSaveText { get; set; } = false;

    public OutputOptions Clone() => (OutputOptions)MemberwiseClone();

    public bool Equals(OutputOptions? other) =>
        other is not null && PdfSize == other.PdfSize && AfterSave == other.AfterSave
        && AlsoSaveText == other.AlsoSaveText;
    public override bool Equals(object? obj) => Equals(obj as OutputOptions);
    public override int GetHashCode() => HashCode.Combine(PdfSize, AfterSave, AlsoSaveText);
}

/// <summary>
/// Settings for the clean-up of document pages, kept together as <see cref="ScanSettings.Document"/>
/// (the "document" object in settings files). Later page features (split) add their fields here;
/// every one is off by default.
/// </summary>
public sealed class DocumentOptions : IEquatable<DocumentOptions>
{
    /// <summary>
    /// Pages that look blank are left out when the queue is saved. They are only flagged in the
    /// page strip, where one click keeps one; nothing is deleted while they are queued.
    /// </summary>
    public bool RemoveBlankPages { get; set; } = false;

    /// <summary>How much may be on a page for it to count as blank.</summary>
    public BlankSensitivity BlankSensitivity { get; set; } = BlankSensitivity.Medium;

    /// <summary>
    /// Each page is cut out of the scanner's background when its edges are clear
    /// (<see cref="DocumentGeometry"/>). One click in the page strip shows a page as scanned.
    /// </summary>
    public bool AutoCrop { get; set; } = false;

    /// <summary>
    /// Each page that lies at a slant is turned straight, by its edges or its lines of text
    /// (<see cref="DocumentGeometry"/>). One click in the page strip shows a page as scanned.
    /// </summary>
    public bool AutoStraighten { get; set; } = false;

    public DocumentOptions Clone() => (DocumentOptions)MemberwiseClone();

    public bool Equals(DocumentOptions? other) =>
        other is not null && RemoveBlankPages == other.RemoveBlankPages && BlankSensitivity == other.BlankSensitivity
        && AutoCrop == other.AutoCrop && AutoStraighten == other.AutoStraighten;
    public override bool Equals(object? obj) => Equals(obj as DocumentOptions);
    public override int GetHashCode() => HashCode.Combine(RemoveBlankPages, BlankSensitivity, AutoCrop, AutoStraighten);
}

/// <summary>
/// Choices that belong to one task, kept together as <see cref="ScanSettings.TaskOptions"/> (the
/// "taskOptions" object in settings files). Picking a task keeps them: they say how the user wants
/// that task done. Later tasks add their fields here.
/// </summary>
public sealed class TaskOptions : IEquatable<TaskOptions>
{
    /// <summary>The page the ID card's sides are laid out on. Settings without it get Automatic.</summary>
    public IdCardPaper IdCardPaper { get; set; } = IdCardPaper.Auto;

    /// <summary>Each side of the ID card is also saved as an image of its own. Off unless chosen.</summary>
    public bool IdCardSaveSidesAsImages { get; set; } = false;

    /// <summary>How many copies the Copy task prints; read through <see cref="PrintCopies.Clamp"/> (1 to 99). One unless chosen.</summary>
    public int CopyCount { get; set; } = 1;

    /// <summary>Copies are made smaller to fit the printable area of the paper. Off: they print at real size, like a photocopier.</summary>
    public bool CopyFitToPage { get; set; } = false;

    /// <summary>
    /// The printer the Copy task (and printing the ID card) prints on; null for the default printer,
    /// which is also used when this one is no longer installed. Left out of the file when null.
    /// </summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? CopyPrinterName { get; set; }

    /// <summary>Each copy is also saved as a PDF in the save folder. Off unless chosen.</summary>
    public bool CopyAlsoSavePdf { get; set; } = false;

    public TaskOptions Clone() => (TaskOptions)MemberwiseClone();

    public bool Equals(TaskOptions? other) =>
        other is not null && IdCardPaper == other.IdCardPaper && IdCardSaveSidesAsImages == other.IdCardSaveSidesAsImages
        && CopyCount == other.CopyCount && CopyFitToPage == other.CopyFitToPage
        && CopyPrinterName == other.CopyPrinterName && CopyAlsoSavePdf == other.CopyAlsoSavePdf;
    public override bool Equals(object? obj) => Equals(obj as TaskOptions);
    public override int GetHashCode() =>
        HashCode.Combine(IdCardPaper, IdCardSaveSidesAsImages, CopyCount, CopyFitToPage, CopyPrinterName, CopyAlsoSavePdf);
}

public static class BlankSensitivities
{
    /// <summary>The levels as the inspector lists them: least first.</summary>
    public static IReadOnlyList<BlankSensitivity> DisplayOrder { get; } =
        [BlankSensitivity.Low, BlankSensitivity.Medium, BlankSensitivity.High];
}

public sealed class ScanSettings
{
    public ScanIntent Intent { get; set; } = ScanIntent.Document;
    public ScanSource Source { get; set; } = ScanSource.Flatbed;
    public int Resolution { get; set; } = 300;
    public ColorMode ColorMode { get; set; } = ColorMode.Color;
    public OutputFormat Format { get; set; } = OutputFormat.Pdf;
    /// <summary>0 ... 1</summary>
    public double JpegQuality { get; set; } = 0.9;
    public string DestinationPath { get; set; } = DefaultDestinationPath;
    public string NamingTemplate { get; set; } = "Scan {date} {counter}";

    // Photo mode
    public bool PhotoAutoSplit { get; set; } = true;
    public bool PhotoAutoDeskew { get; set; } = true;
    /// <summary>Smallest photo side considered a real photo (inches).</summary>
    public double PhotoMinSideInches { get; set; } = 1.2;
    /// <summary>Pixels (at scan resolution) shaved off each detected photo edge to remove background slivers.</summary>
    public int PhotoCropInsetPixels { get; set; } = 0;

    // Document / PDF mode
    /// <summary>
    /// true: scans accumulate as pages and are saved together with "Save PDF".
    /// false: every scan is written to disk immediately as its own file.
    /// </summary>
    public bool DocumentMultiPage { get; set; } = true;
    /// <summary>Run OCR and embed an invisible text layer in saved PDFs.</summary>
    public bool PdfSearchable { get; set; } = true;
    /// <summary>
    /// No longer used: recognition is universal (see <see cref="IOcrService"/>). Kept so
    /// settings and preset files written by older versions still round-trip unchanged.
    /// </summary>
    [Obsolete("OCR recognizes every supported language automatically; this setting is ignored.")]
    public List<string> OcrLanguages { get; set; } = ["en-US"];

    public AdjustmentSettings Adjustments { get; set; } = new();

    /// <summary>
    /// The task these settings were set up for (<see cref="ScanTasks.RawValue"/>), or null for
    /// settings chosen by hand. Kept as text: a task this version does not know (written by a
    /// newer one) reads as no <see cref="Task"/> but is written back unchanged. Left out of the
    /// file when null.
    /// </summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? TaskId { get; set; }

    /// <summary>The task of <see cref="TaskId"/>, when this version knows it.</summary>
    [JsonIgnore]
    public ScanTask? Task => ScanTasks.TryParse(TaskId);

    /// <summary>Settings for the saved files (the PDF size, the after-save action, the text beside a PDF). Written after the earlier keys.</summary>
    public OutputOptions Output { get; set; } = new();

    /// <summary>
    /// Which sides of each sheet a feeder scan captures. Read by the backends (two-sided feeder
    /// scans) and the app (turning the stack over by hand); ignored on the flatbed. Settings
    /// without it scan one side.
    /// </summary>
    public DuplexMode Duplex { get; set; } = DuplexMode.Off;

    /// <summary>Along which edge the back sides are turned; the backs of short-edge sheets are turned upright.</summary>
    public DuplexBinding BackBinding { get; set; } = DuplexBinding.LongEdge;

    /// <summary>
    /// The size of the paper scanned (<see cref="PaperSizes"/>): the area of the glass scanned
    /// when no area is selected, or the sheet the feeder is asked for. Automatic scans the whole
    /// glass, or the feeder's own sheet size.
    /// </summary>
    public PaperSize PaperSize { get; set; } = PaperSize.Auto;

    /// <summary>Clean-up of document pages (blank pages). Written after the earlier keys.</summary>
    public DocumentOptions Document { get; set; } = new();

    /// <summary>Choices of particular tasks (the ID card's page). Written after the earlier keys.</summary>
    public TaskOptions TaskOptions { get; set; } = new();

    public static string DefaultDestinationPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "CompleteScanner");

    public ScanSettings Clone()
    {
        var copy = (ScanSettings)MemberwiseClone();
#pragma warning disable CS0618 // deep-copy the legacy field so the clone stays independent
        copy.OcrLanguages = [.. OcrLanguages];
#pragma warning restore CS0618
        copy.Adjustments = Adjustments.Clone();
        copy.Output = Output.Clone();
        copy.Document = Document.Clone();
        copy.TaskOptions = TaskOptions.Clone();
        return copy;
    }
}

// MARK: - Runtime objects

public sealed class ScannedPage
{
    public Guid Id { get; }
    /// <summary>
    /// Page pixels. When <see cref="FilePath"/> is set this is a lower-resolution preview;
    /// the full-resolution original lives in the file.
    /// </summary>
    public RgbaImage Image { get; }
    public int Dpi { get; }
    public ColorMode ColorMode { get; }
    public DateTime CreatedAt { get; }
    /// <summary>
    /// Full-resolution spill file backing this page when it was offloaded from memory.
    /// Consumers that need full pixels reload from it.
    /// </summary>
    public string? FilePath { get; }
    /// <summary>
    /// Pixel dimensions of the full-resolution original (recorded when the page is spooled),
    /// so physical page size stays correct even if only the preview is available.
    /// </summary>
    public SizeD? FullPixelSize { get; }
    /// <summary>
    /// User-requested rotation applied at save time (0...3 quarter turns clockwise).
    /// <see cref="Image"/> already shows the rotation; the full-resolution original (spool
    /// file) stays unrotated until <see cref="PdfBuilder.PreparePage"/> applies it.
    /// </summary>
    public int RotationQuarterTurns { get; set; } = 0;

    /// <summary>Which side of its sheet this page is, for two-sided scans; null for one-sided ones.</summary>
    public PageSide? Side { get; init; }

    /// <summary>The sheet of the stack this page belongs to (0 = first), for two-sided scans; null otherwise.</summary>
    public int? SheetIndex { get; init; }

    /// <summary>
    /// What the blank-page check found on the page as scanned (<see cref="BlankPageDetector"/>),
    /// or null when it was not checked (photos, pages scanned one file at a time).
    /// </summary>
    public BlankPageResult? Blank { get; init; }

    /// <summary>Whether the user keeps or skips this page whatever the blank-page setting.</summary>
    public PageInclusion Inclusion { get; init; } = PageInclusion.Automatic;

    /// <summary>
    /// What crop and straighten did to the page (<see cref="DocumentGeometry"/>), or null when they
    /// did nothing (off, or not sure).
    /// </summary>
    public PageGeometry? Geometry { get; init; }

    /// <summary>
    /// The user went back to the page as scanned: <see cref="Image"/> is the page before crop and
    /// straighten, <see cref="Alternate"/> the cropped and straightened one.
    /// </summary>
    public bool ShowsOriginal { get; init; }

    /// <summary>
    /// The version of the page not shown (the page as scanned, or after crop and straighten), so
    /// one click can swap them; null when there is none. Its pixels are dropped once it has a spool
    /// file. Pixel steps after crop and straighten change it too (<see cref="WithAlternate"/>).
    /// </summary>
    public PageVersion? Alternate { get; init; }

    /// <summary>The page was cropped or straightened and the other version is at hand: one click swaps them.</summary>
    public bool CanSwapVersions => Geometry is not null && Alternate is not null;

    public ScannedPage(RgbaImage image, int dpi, ColorMode colorMode, Guid? id = null,
                       DateTime? createdAt = null, string? filePath = null, SizeD? fullPixelSize = null)
    {
        Id = id ?? Guid.NewGuid();
        Image = image;
        Dpi = dpi;
        ColorMode = colorMode;
        CreatedAt = createdAt ?? DateTime.Now;
        FilePath = filePath;
        FullPixelSize = fullPixelSize;
    }

    /// <summary>
    /// The same page with other pixels: adjusted, or a preview backed by a spool file. The id,
    /// resolution, creation time, rotation and what the scan recorded about the page
    /// (<see cref="CopyMeta"/>) are kept; the color mode is <paramref name="colorMode"/> when
    /// given; the spool file and full size are the ones given (none by default), since the old
    /// ones belong to the old pixels. Every place that rebuilds a page goes through this, so new
    /// page facts survive.
    /// </summary>
    public ScannedPage WithImage(RgbaImage image, ColorMode? colorMode = null, string? filePath = null,
                                 SizeD? fullPixelSize = null) =>
        new ScannedPage(image, Dpi, colorMode ?? ColorMode, Id, CreatedAt, filePath, fullPixelSize)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Alternate = Alternate,
        }.CopyMeta(this);

    /// <summary>
    /// This page carrying what the scan recorded about <paramref name="source"/>: its side and
    /// sheet, the blank-page check, the user's keep or skip, and what crop and straighten did and
    /// which version is shown. Pixels, id, file, rotation and the other version stay this page's.
    /// </summary>
    public ScannedPage CopyMeta(ScannedPage source) =>
        new(Image, Dpi, ColorMode, Id, CreatedAt, FilePath, FullPixelSize)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Side = source.Side,
            SheetIndex = source.SheetIndex,
            Blank = source.Blank,
            Inclusion = source.Inclusion,
            Geometry = source.Geometry,
            ShowsOriginal = source.ShowsOriginal,
            Alternate = Alternate,
        };

    /// <summary>This page as <paramref name="side"/> of sheet <paramref name="sheetIndex"/> (both null: not two-sided).</summary>
    public ScannedPage WithSide(PageSide? side, int? sheetIndex) =>
        new(Image, Dpi, ColorMode, Id, CreatedAt, FilePath, FullPixelSize)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Side = side,
            SheetIndex = sheetIndex,
            Blank = Blank,
            Inclusion = Inclusion,
            Geometry = Geometry,
            ShowsOriginal = ShowsOriginal,
            Alternate = Alternate,
        };

    /// <summary>This page with what the blank-page check found (null: not checked).</summary>
    public ScannedPage WithBlank(BlankPageResult? blank) =>
        new(Image, Dpi, ColorMode, Id, CreatedAt, FilePath, FullPixelSize)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Side = Side,
            SheetIndex = SheetIndex,
            Blank = blank,
            Inclusion = Inclusion,
            Geometry = Geometry,
            ShowsOriginal = ShowsOriginal,
            Alternate = Alternate,
        };

    /// <summary>This page kept, skipped, or following the blank-page setting again.</summary>
    public ScannedPage WithInclusion(PageInclusion inclusion) =>
        new(Image, Dpi, ColorMode, Id, CreatedAt, FilePath, FullPixelSize)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Side = Side,
            SheetIndex = SheetIndex,
            Blank = Blank,
            Inclusion = inclusion,
            Geometry = Geometry,
            ShowsOriginal = ShowsOriginal,
            Alternate = Alternate,
        };

    /// <summary>
    /// This page cropped or straightened: <paramref name="corrected"/> is shown, with what was done
    /// (<paramref name="geometry"/>), and the page as it was becomes the <see cref="Alternate"/>.
    /// </summary>
    public ScannedPage WithGeometry(RgbaImage corrected, PageGeometry geometry) =>
        new(corrected, Dpi, ColorMode, Id, CreatedAt)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Side = Side,
            SheetIndex = SheetIndex,
            Blank = Blank,
            Inclusion = Inclusion,
            Geometry = geometry,
            ShowsOriginal = false,
            Alternate = new PageVersion(Image, FilePath, FullPixelSize),
        };

    /// <summary>This page with another version not shown (null: none).</summary>
    public ScannedPage WithAlternate(PageVersion? alternate) =>
        new(Image, Dpi, ColorMode, Id, CreatedAt, FilePath, FullPixelSize)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Side = Side,
            SheetIndex = SheetIndex,
            Blank = Blank,
            Inclusion = Inclusion,
            Geometry = Geometry,
            ShowsOriginal = ShowsOriginal,
            Alternate = alternate,
        };

    /// <summary>
    /// The other version shown: the page as scanned instead of the cropped and straightened one, or
    /// back. <paramref name="shown"/> is the other version's pixels as the queue shows them (its
    /// preview, turned like this page; <see cref="Alternate"/>'s own pixels when it has no spool
    /// file). This version becomes the alternate, without its pixels when it has a spool file. A
    /// page with no other version is returned as it is.
    /// </summary>
    public ScannedPage WithVersionsSwapped(RgbaImage shown)
    {
        if (Alternate is not { } other) return this;
        return new ScannedPage(shown, Dpi, ColorMode, Id, CreatedAt, other.FilePath, other.FullPixelSize)
        {
            RotationQuarterTurns = RotationQuarterTurns,
            Side = Side,
            SheetIndex = SheetIndex,
            Blank = Blank,
            Inclusion = Inclusion,
            Geometry = Geometry,
            ShowsOriginal = !ShowsOriginal,
            Alternate = new PageVersion(FilePath is null ? Image : null, FilePath, FullPixelSize),
        };
    }

    /// <summary>
    /// The page turned 90° clockwise: the in-memory image is rotated right away (thumbnails
    /// follow it) while the spool file stays untouched and the accumulated turn count is
    /// applied at save time. The other version's pixels in memory turn with it. Port of
    /// AppState.rotatePage(id:).
    /// </summary>
    public ScannedPage RotatedClockwise() =>
        new ScannedPage(ImagePipeline.Rotate(Image, 1), Dpi, ColorMode, Id, CreatedAt, FilePath, FullPixelSize)
        {
            RotationQuarterTurns = (RotationQuarterTurns + 1) % 4,
            Alternate = Alternate is { Image: { } other } version ? version with { Image = ImagePipeline.Rotate(other, 1) } : Alternate,
        }.CopyMeta(this);
}

/// <summary>
/// One version of a queued page (<see cref="ScannedPage.Alternate"/>): its pixels as the queue shows
/// them (null once spooled), its full-resolution spool file and that file's pixel size.
/// </summary>
public sealed record PageVersion(RgbaImage? Image, string? FilePath, SizeD? FullPixelSize);

/// <summary>
/// A rotated rectangle found on a scanned flatbed image.
///
/// Coordinate convention: source-image pixels, origin at TOP-LEFT, x right, y down.
/// <c>AngleDegrees</c> is the rotation of the rectangle; a positive angle appears as a
/// CLOCKWISE rotation on screen. Normalized to (-45, 45]. A point (x, y) in the
/// rectangle's local frame maps to the image as:
///   ix = center.X + x*cos(a) - y*sin(a)
///   iy = center.Y + x*sin(a) + y*cos(a)
/// </summary>
public sealed class DetectedPhotoRegion : IEquatable<DetectedPhotoRegion>
{
    public Guid Id { get; }
    public PointD Center { get; set; }
    public SizeD Size { get; set; }
    public double AngleDegrees { get; set; }

    public DetectedPhotoRegion(PointD center, SizeD size, double angleDegrees, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Center = center;
        Size = size;
        AngleDegrees = angleDegrees;
    }

    /// <summary>Corners in source-image pixel coordinates (top-left origin), order: TL, TR, BR, BL of the local frame.</summary>
    public PointD[] Corners()
    {
        double a = AngleDegrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        double hw = Size.Width / 2, hh = Size.Height / 2;
        var local = new[]
        {
            new PointD(-hw, -hh), new PointD(hw, -hh), new PointD(hw, hh), new PointD(-hw, hh),
        };
        var result = new PointD[4];
        for (int i = 0; i < 4; i++)
        {
            result[i] = new PointD(Center.X + local[i].X * c - local[i].Y * s,
                                   Center.Y + local[i].X * s + local[i].Y * c);
        }
        return result;
    }

    /// <summary>Axis-aligned bounding box of <see cref="Corners"/>.</summary>
    public RectD BoundingBox()
    {
        var pts = Corners();
        double minX = pts.Min(p => p.X), minY = pts.Min(p => p.Y);
        double maxX = pts.Max(p => p.X), maxY = pts.Max(p => p.Y);
        return new RectD(minX, minY, maxX - minX, maxY - minY);
    }

    public bool Equals(DetectedPhotoRegion? other) =>
        other is not null && Id == other.Id && Center == other.Center
        && Size == other.Size && AngleDegrees == other.AngleDegrees;
    public override bool Equals(object? obj) => Equals(obj as DetectedPhotoRegion);
    public override int GetHashCode() => HashCode.Combine(Id, Center, Size, AngleDegrees);
}

public sealed class DetectedPhoto
{
    public Guid Id { get; }
    public DetectedPhotoRegion Region { get; }
    public RgbaImage Image { get; }
    public int Dpi { get; }
    /// <summary>
    /// The scanned page this photo was extracted from — a multi-sheet (ADF) photo scan
    /// produces photos from several pages, and manual re-cropping must use the right one.
    /// </summary>
    public Guid? SourcePageId { get; }
    public bool Included { get; set; } = true;
    /// <summary>Extra user-requested rotation applied at save time (0...3 quarter turns clockwise).</summary>
    public int RotationQuarterTurns { get; set; } = 0;

    public DetectedPhoto(DetectedPhotoRegion region, RgbaImage image, int dpi, Guid? id = null,
                         Guid? sourcePageId = null)
    {
        Id = id ?? Guid.NewGuid();
        Region = region;
        Image = image;
        Dpi = dpi;
        SourcePageId = sourcePageId;
    }

    /// <summary>
    /// Manual crop correction: the same photo (id, source page, inclusion, rotation) with a
    /// user-adjusted region and its re-extracted pixels (see
    /// <see cref="PhotoDetector.ExtractPhoto"/>). Port of AppState.recropPhoto(id:region:).
    /// </summary>
    public DetectedPhoto Recropped(DetectedPhotoRegion region, RgbaImage image) =>
        new(region, image, Dpi, Id, SourcePageId)
        {
            Included = Included,
            RotationQuarterTurns = RotationQuarterTurns,
        };
}

/// <summary>
/// One entry in the session's scan history ("Scans" tab): a small preview of every scan
/// as it happened, newest first.
/// </summary>
public sealed class ScanHistoryEntry
{
    public Guid Id { get; }
    public DateTime Date { get; }
    public ScanIntent Intent { get; }
    public int Dpi { get; }
    /// <summary>Downsampled preview (≤ ~700 px long side) — history never retains full pixels.</summary>
    public RgbaImage Thumbnail { get; }
    /// <summary>True pixel dimensions of the original scan.</summary>
    public SizeD PixelSize { get; }

    public ScanHistoryEntry(DateTime date, ScanIntent intent, int dpi, RgbaImage thumbnail,
                            SizeD pixelSize, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Date = date;
        Intent = intent;
        Dpi = dpi;
        Thumbnail = thumbnail;
        PixelSize = pixelSize;
    }
}

/// <summary>
/// The scan-history bookkeeping from AppState's scan handler, extracted so every shell
/// records history identically.
/// </summary>
public static class ScanHistory
{
    /// <summary>Long side of a history thumbnail, in pixels.</summary>
    public const int ThumbnailMaxSide = 700;
    /// <summary>Entries kept; older ones are dropped.</summary>
    public const int MaxEntries = 50;

    /// <summary>One entry per raw (unadjusted, unspooled) scanned page, in scan order.</summary>
    public static List<ScanHistoryEntry> MakeEntries(IReadOnlyList<ScannedPage> rawPages,
                                                     ScanIntent intent, DateTime date) =>
        rawPages.Select(page => new ScanHistoryEntry(
            date, intent, page.Dpi, MakePreview(page.Image, ThumbnailMaxSide),
            new SizeD(page.Image.Width, page.Image.Height))).ToList();

    /// <summary>
    /// Insert a batch at the front of <paramref name="history"/> (newest first, so the last
    /// page of the batch leads) and drop everything beyond <see cref="MaxEntries"/>.
    /// </summary>
    public static void Record(List<ScanHistoryEntry> history, IReadOnlyList<ScanHistoryEntry> entries)
    {
        history.InsertRange(0, entries.Reverse());
        if (history.Count > MaxEntries)
            history.RemoveRange(MaxEntries, history.Count - MaxEntries);
    }

    /// <summary>Downscale so the long side is at most <paramref name="maxSide"/>; smaller images pass through.</summary>
    public static RgbaImage MakePreview(RgbaImage image, int maxSide)
    {
        int longSide = Math.Max(image.Width, image.Height);
        if (longSide <= maxSide) return image;
        double scale = (double)maxSide / longSide;
        return image.Resized(Math.Max(1, (int)(image.Width * scale)),
                             Math.Max(1, (int)(image.Height * scale)));
    }
}

// MARK: - Devices

/// <summary>
/// One device as one backend lists it. The same physical scanner can appear once per
/// backend or connection; <see cref="DeviceMerge"/> groups those entries into one row.
/// </summary>
/// <param name="Transport">"USB", "Network", "Shared", "Demo", "WIA", ...</param>
/// <param name="Backend">
/// The backend listing the device: "wia", "twain", "escl", "ic" (ImageCaptureCore) or "mock";
/// empty when unknown. Together with <paramref name="Transport"/> it names the connection.
/// </param>
/// <param name="Model">Manufacturer and model as the device reports them, when known; used to match entries.</param>
/// <param name="HardwareId">
/// An identifier of the physical device (eSCL UUID, serial number), when known. Two entries
/// that both have one are the same scanner only when the identifiers match.
/// </param>
public sealed record ScannerInfo(string Id, string Name, string Transport, bool IsDemo = false,
                                 string Backend = "", string? Model = null, string? HardwareId = null);

public sealed class ScannerCapabilities
{
    public List<int> SupportedResolutions { get; set; } = [75, 150, 200, 300, 600, 1200];
    public List<ScanSource> Sources { get; set; } = [ScanSource.Flatbed];
    /// <summary>Physical flatbed size in inches.</summary>
    public SizeD FlatbedSizeInches { get; set; } = new(8.5, 11.7);
    public bool SupportsOverview { get; set; } = true;
    /// <summary>
    /// Largest sheet the document feeder takes, in inches; null when the device has no feeder
    /// or does not report it.
    /// </summary>
    public SizeD? FeederSizeInches { get; set; }
    /// <summary>
    /// The document feeder can scan both sides in one pass. Without it, two-sided scanning is
    /// done by turning the stack over by hand (<see cref="DocumentSides.Effective"/>).
    /// </summary>
    public bool SupportsDuplex { get; set; }

    public int NearestResolution(int dpi) =>
        SupportedResolutions.Count == 0
            ? dpi
            : SupportedResolutions.MinBy(r => Math.Abs(r - dpi));
}

/// <param name="Fraction">null = indeterminate</param>
public sealed record ScanProgress(double? Fraction, string Message)
{
    public ScanProgress(string message) : this(null, message) { }
}

// MARK: - Presets

public sealed class Preset
{
    /// <summary>Name given to a stored preset whose name is missing or unreadable.</summary>
    internal const string FallbackName = "Untitled preset";

    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = FallbackName;
    public ScanSettings Settings { get; set; } = new();

    public Preset() { }

    public Preset(string name, ScanSettings settings)
    {
        Name = name;
        Settings = settings;
    }
}

// MARK: - Errors

public enum ScanErrorKind
{
    DeviceUnavailable,
    SessionFailed,
    ScanFailed,
    Cancelled,
    ExportFailed,
    Unsupported,
}

/// <summary>Port of Swift's ScanError: one exception type with a kind and a user-facing message.</summary>
public sealed class ScanException : Exception
{
    public ScanErrorKind Kind { get; }
    /// <summary>The scanner condition behind this error, when the backend could tell.</summary>
    public ScannerProblem? Problem { get; }

    private ScanException(ScanErrorKind kind, string message, ScannerProblem? problem = null) : base(message)
    {
        Kind = kind;
        Problem = problem;
    }

    /// <summary>
    /// An error caused by a condition at the scanner. The message is the problem's
    /// user-facing text (<see cref="ScannerProblems.Describe"/>); <paramref name="detail"/>,
    /// such as a driver error code, is appended in parentheses.
    /// </summary>
    public static ScanException ForProblem(ScannerProblem problem, string? detail = null)
    {
        string message = ScannerProblems.Describe(problem);
        if (!string.IsNullOrWhiteSpace(detail)) message += $" ({detail})";
        return new(ScannerProblems.Kind(problem), message, problem);
    }

    public static ScanException DeviceUnavailable(string detail) =>
        new(ScanErrorKind.DeviceUnavailable, $"Scanner unavailable: {detail}");
    public static ScanException SessionFailed(string detail) =>
        new(ScanErrorKind.SessionFailed, $"Could not open a session with the scanner: {detail}");
    public static ScanException ScanFailed(string detail) =>
        new(ScanErrorKind.ScanFailed, $"Scan failed: {detail}");
    public static ScanException Cancelled() =>
        new(ScanErrorKind.Cancelled, "The scan was cancelled.");
    public static ScanException ExportFailed(string detail) =>
        new(ScanErrorKind.ExportFailed, $"Saving failed: {detail}");
    public static ScanException Unsupported(string detail) =>
        new(ScanErrorKind.Unsupported, $"Unsupported: {detail}");
}
