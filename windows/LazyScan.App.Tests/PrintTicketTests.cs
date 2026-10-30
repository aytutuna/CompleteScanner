using System.Printing;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// A print job's ticket starts as a copy of the preferences saved for the printer; whatever they say,
// the job sets what the copy relies on. Checked on tickets alone: nothing is sent to a printer.
// Windows only: the Mac prints through the print panel, which shows these settings.
public class PrintTicketTests
{
    private static readonly Collation[] Collates = [Collation.Collated, Collation.Uncollated];
    private static readonly OutputColor[] Colors = [OutputColor.Color, OutputColor.Grayscale, OutputColor.Monochrome];
    private static readonly Duplexing[] Sides = [Duplexing.OneSided, Duplexing.TwoSidedLongEdge, Duplexing.TwoSidedShortEdge];

    private static PrintJob Job(PrintCopiesPlan copies, bool gray = false, int pages = 1) =>
        new("Test printer", "Copy", PrinterPaper.Make(new SizeD(8.5, 11), null), null,
            Enumerable.Range(0, pages)
                .Select(_ => new PrintPage(RgbaImage.Filled(2, 2, 255, 255, 255), 300, new PrintPlacement(new RectD(0, 0, 1, 1), 1, 0, 0)))
                .ToList(),
            copies, gray);

    /// <summary>Preferences a user may have saved for the printer: 2 copies, 2 pages per sheet, both sides, grey, not collated.</summary>
    private static PrintTicket Preferences() => new()
    {
        CopyCount = 2,
        PagesPerSheet = 2,
        Duplexing = Duplexing.TwoSidedLongEdge,
        OutputColor = OutputColor.Grayscale,
        Collation = Collation.Uncollated,
    };

    [Fact]
    public void OneCopy_ThePreferencesDoNotCarryIntoIt()
    {
        var ticket = Preferences();
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(1, 1)), Collates, Colors, Sides);
        Assert.Equal(1, ticket.CopyCount);
        Assert.Equal(Duplexing.OneSided, ticket.Duplexing);
        Assert.Equal(OutputColor.Color, ticket.OutputColor);
        Assert.Equal(1, ticket.PagesPerSheet);
    }

    [Fact]
    public void PagesPerSheetSavedForThePrinter_OnePagePerSheet()
    {
        // Two pages on a sheet would print each at about 70 %: a copy, an ID card page or the ruler
        // page would no longer be real size.
        var ticket = new PrintTicket { PagesPerSheet = 2 };
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(1, 1)), Collates, Colors, Sides);
        Assert.Equal(1, ticket.PagesPerSheet);

        ticket = new PrintTicket { PagesPerSheet = 4 };
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(3, 1), pages: 2), Collates, Colors, Sides);
        Assert.Equal(1, ticket.PagesPerSheet);
    }

    [Fact]
    public void CopiesRepeatedInTheDocument_OneCopyOfIt_OnOneSide()
    {
        // Three copies of three pages as one nine-page document: printed on both sides, page 1 of the
        // second copy would land on the back of page 3 of the first.
        var ticket = Preferences();
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(1, 3), pages: 3), Collates, Colors, Sides);
        Assert.Equal(1, ticket.CopyCount);
        Assert.Equal(Duplexing.OneSided, ticket.Duplexing);
    }

    [Fact]
    public void CopiesThePrinterMakes_Collated()
    {
        var ticket = Preferences();
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(3, 1), pages: 2), Collates, Colors, Sides);
        Assert.Equal(3, ticket.CopyCount);
        Assert.Equal(Collation.Collated, ticket.Collation);
        Assert.Equal(Duplexing.OneSided, ticket.Duplexing);
    }

    [Fact]
    public void GreyJob_GreyOrBlackAndWhite_AsThePrinterLists()
    {
        var ticket = new PrintTicket { OutputColor = OutputColor.Color };
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(1, 1), gray: true), Collates, Colors, Sides);
        Assert.Equal(OutputColor.Grayscale, ticket.OutputColor);

        ticket = new PrintTicket { OutputColor = OutputColor.Color };
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(1, 1), gray: true), Collates,
                                             [OutputColor.Color, OutputColor.Monochrome], Sides);
        Assert.Equal(OutputColor.Monochrome, ticket.OutputColor);
    }

    [Fact]
    public void ColourJob_OnAPrinterWithoutColour_KeepsWhatItHas()
    {
        var ticket = new PrintTicket { OutputColor = OutputColor.Monochrome };
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(1, 1)), Collates, [OutputColor.Monochrome], Sides);
        Assert.Equal(OutputColor.Monochrome, ticket.OutputColor);
    }

    [Fact]
    public void PrinterWithoutCollating_ACollatedCopyIsNotAskedOf()
    {
        // PrintCopies.Plan repeats the pages in the document instead (PrinterSetup.CanCollate).
        var ticket = Preferences();
        WindowsPrintService.ApplyJobSettings(ticket, Job(new PrintCopiesPlan(3, 1)), [Collation.Uncollated], Colors, [Duplexing.OneSided]);
        Assert.Equal(3, ticket.CopyCount);
        Assert.Equal(Collation.Uncollated, ticket.Collation);
        Assert.Equal(Duplexing.OneSided, ticket.Duplexing);
    }
}
