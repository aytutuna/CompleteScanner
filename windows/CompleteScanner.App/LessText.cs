namespace CompleteScanner.App;

/// <summary>
/// The short visible texts only the Windows layout has: the empty stage's line and chip, and the
/// short reasons of controls the Mac lays out differently. The short texts both apps show (disabled
/// reasons, consequence lines, the status line, the inspector's summaries) are in Core
/// (<see cref="CompleteScanner.Core.StatusLine"/>, <see cref="CompleteScanner.Core.InspectorSections"/>
/// and the types they belong to).
/// </summary>
internal static class ShortText
{
    /// <summary>The empty stage's line without a task.</summary>
    public const string PlaceOriginal = "Place the original face down, then select Scan.";
    /// <summary>The chip on a preview until an area is selected.</summary>
    public const string DragToSelect = "Drag to select an area";
    /// <summary>Page clean-up and splitting while each scan is saved at once.</summary>
    public const string NeedsCollectPages = "Needs Collect pages";
    /// <summary>Skip blank pages while blank sheets split the stack into documents.</summary>
    public const string BlankSheetsSplit = "Blank sheets split documents";
    /// <summary>Receipts in one PDF, while they are saved as images.</summary>
    public const string OnlyForPdfs = "Only for PDFs";
    /// <summary>Name by receipt date while the file name has no {docdate}: the receipt's date is not used.</summary>
    public const string NeedsDocDate = "Needs {docdate} in File name";
}
