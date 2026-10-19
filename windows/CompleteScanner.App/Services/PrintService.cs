using System.ComponentModel;
using System.IO;
using System.Printing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Xps;
using CompleteScanner.Core;

namespace CompleteScanner.App.Services;

/// <summary>A printer Windows lists, by the name the print system knows it by.</summary>
public sealed record PrinterInfo(string Name, bool IsDefault);

/// <summary>
/// What printing on a printer would use: the paper (the one asked for when the printer has it,
/// else its own) and the part of it it prints on, the most copies it makes itself (null when it
/// does not say), whether it can print in grey, and whether it collates the copies it makes.
/// </summary>
public sealed record PrinterSetup(string PrinterName, PrinterPaper Paper, int? MaxCopyCount, bool CanPrintGray,
                                  bool CanCollate = true);

/// <summary>One page of a print job: the pixels at their resolution, and where they go on the paper (<see cref="PrintLayout"/>).</summary>
public sealed record PrintPage(RgbaImage Image, int Dpi, PrintPlacement Placement);

/// <summary>
/// A print job: the pages in order on <paramref name="Paper"/> (the paper of <see cref="PrinterSetup"/>,
/// asked for again as <paramref name="RequestedPaper"/>), printed as <paramref name="Copies"/> says,
/// in grey when <paramref name="Gray"/>.
/// </summary>
public sealed record PrintJob(string PrinterName, string JobName, PrinterPaper Paper, PaperSize? RequestedPaper,
                              IReadOnlyList<PrintPage> Pages, PrintCopiesPlan Copies, bool Gray)
{
    /// <summary>Pages in the document: every page, as many times as the copies are repeated in it.</summary>
    public int DocumentPageCount => Pages.Count * Math.Max(1, Copies.DocumentRepeats);
}

/// <summary>Printing could not be done; the message says why, for the user.</summary>
public sealed class PrintException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>
/// Printing through Windows: the printers, what a printer offers, and sending a job to it, with
/// no print dialog. <see cref="AppViewModel"/> decides what to print (with <see cref="PrintLayout"/>);
/// this carries it out, so tests can stand in for the printers. Every member may be called from
/// any thread.
/// </summary>
public interface IPrintService
{
    /// <summary>The installed printers, local and connected; empty when there are none.</summary>
    /// <exception cref="PrintException">The print system cannot be read (its service is stopped, say): whether there are printers is not known.</exception>
    Task<IReadOnlyList<PrinterInfo>> GetPrintersAsync();

    /// <summary>
    /// What printing on <paramref name="printerName"/> (null: the default printer) would use, with
    /// <paramref name="requestedPaper"/> when the printer has that paper (null: its own paper); null
    /// when there is no such printer.
    /// </summary>
    Task<PrinterSetup?> GetSetupAsync(string? printerName, PaperSize? requestedPaper);

    /// <summary>Sends the job to its printer; cancelling stops writing the document and drops the job.</summary>
    /// <exception cref="PrintException">The printer refused the job or is gone.</exception>
    Task PrintAsync(PrintJob job, CancellationToken token);
}

/// <summary>
/// The Windows implementation, on System.Printing and the XPS print path (part of WPF; no
/// package). Each call runs on its own STA thread, as the print system's objects expect. Pages
/// are placed on paper-sized fixed pages at the size <see cref="PrintLayout"/> gives, in
/// 1/96-inch units, so nothing is scaled to the page by the app; the job asks for no scaling either.
/// </summary>
public sealed class WindowsPrintService : IPrintService
{
    public Task<IReadOnlyList<PrinterInfo>> GetPrintersAsync() => StaWork.Run<IReadOnlyList<PrinterInfo>>(() =>
    {
        try
        {
            using var server = new LocalPrintServer();
            string? defaultName = DefaultQueueName();
            using var queues = server.GetPrintQueues([EnumeratedPrintQueueTypes.Local, EnumeratedPrintQueueTypes.Connections]);
            var printers = new List<PrinterInfo>();
            foreach (var queue in queues)
            {
                using (queue)
                {
                    printers.Add(new PrinterInfo(queue.FullName, string.Equals(queue.FullName, defaultName, StringComparison.OrdinalIgnoreCase)));
                }
            }
            return printers;
        }
        catch (Exception e) when (IsPrintSystemError(e))
        {
            throw new PrintException($"Could not read the printers: {e.Message}", e);
        }
    });

    public Task<PrinterSetup?> GetSetupAsync(string? printerName, PaperSize? requestedPaper) => StaWork.Run<PrinterSetup?>(() =>
    {
        try
        {
            using var server = new LocalPrintServer();
            if (Prepare(server, printerName, requestedPaper) is not { } prepared) return null;
            using var queue = prepared.Queue;
            return SetupOf(queue, prepared.Ticket, prepared.Capabilities);
        }
        catch (Exception e) when (IsPrintSystemError(e))
        {
            return null;
        }
    });

    public Task PrintAsync(PrintJob job, CancellationToken token) => StaWork.RunAsync(async () =>
    {
        token.ThrowIfCancellationRequested();
        LocalPrintServer? server = null;
        PrintQueue? queue = null;
        try
        {
            server = new LocalPrintServer();
            var prepared = Prepare(server, job.PrinterName, job.RequestedPaper)
                           ?? throw new PrintException($"The printer {job.PrinterName} is not installed any more.");
            queue = prepared.Queue;
            var ticket = prepared.Ticket;
            var caps = prepared.Capabilities;
            ApplyJobSettings(ticket, job, caps.CollationCapability, caps.OutputColorCapability, caps.DuplexingCapability);
            var validated = queue.MergeAndValidatePrintTicket(queue.UserPrintTicket ?? queue.DefaultPrintTicket, ticket).ValidatedPrintTicket;
            queue.CurrentJobSettings.Description = job.JobName;
            var writer = PrintQueue.CreateXpsDocumentWriter(queue);
            await PrintDocument.WriteAsync(writer, job, validated, token);
        }
        catch (Exception e) when (e is not OperationCanceledException and not PrintException && IsPrintSystemError(e))
        {
            throw new PrintException($"Could not print on {job.PrinterName}: {e.Message}", e);
        }
        finally
        {
            queue?.Dispose();
            server?.Dispose();
        }
    });

    /// <summary>
    /// Sets on <paramref name="ticket"/> (a copy of the printer's saved preferences) everything the
    /// job relies on, so no preference saved for the printer changes it: the copy count of the plan
    /// (1 included), collated when the printer makes several copies and lists collating, one page
    /// per sheet (several pages on a sheet would shrink them from real size), one-sided (the app
    /// lays out each page on a sheet of its own, and copies repeated in the document must not share
    /// sheets), and grey for a grey job, else colour when the printer lists it.
    /// <paramref name="collations"/>, <paramref name="colors"/> and <paramref name="duplexings"/>
    /// are what the printer lists.
    /// </summary>
    public static void ApplyJobSettings(PrintTicket ticket, PrintJob job, IReadOnlyCollection<Collation> collations,
                                        IReadOnlyCollection<OutputColor> colors, IReadOnlyCollection<Duplexing> duplexings)
    {
        ticket.CopyCount = Math.Max(1, job.Copies.TicketCopies);
        if (job.Copies.TicketCopies > 1 && collations.Contains(Collation.Collated)) ticket.Collation = Collation.Collated;
        ticket.PagesPerSheet = 1;
        if (duplexings.Count == 0 || duplexings.Contains(Duplexing.OneSided)) ticket.Duplexing = Duplexing.OneSided;
        if (job.Gray)
        {
            if (colors.Contains(OutputColor.Grayscale)) ticket.OutputColor = OutputColor.Grayscale;
            else if (colors.Contains(OutputColor.Monochrome)) ticket.OutputColor = OutputColor.Monochrome;
        }
        else if (colors.Contains(OutputColor.Color))
        {
            ticket.OutputColor = OutputColor.Color;
        }
    }

    /// <summary>The default printer's name; null when there is none.</summary>
    private static string? DefaultQueueName()
    {
        try
        {
            using var queue = LocalPrintServer.GetDefaultPrintQueue();
            return queue.FullName;
        }
        catch (Exception e) when (IsPrintSystemError(e))
        {
            return null;
        }
    }

    private static bool IsPrintSystemError(Exception e) =>
        e is PrintSystemException or Win32Exception or InvalidOperationException or IOException
            or UnauthorizedAccessException or System.Runtime.InteropServices.COMException;

    private sealed record Prepared(PrintQueue Queue, PrintTicket Ticket, PrintCapabilities Capabilities);

    /// <summary>
    /// The queue <paramref name="printerName"/> (the default one for null) and a portrait ticket on
    /// its own paper, or on <paramref name="requestedPaper"/> when the printer has it; null when there
    /// is no such printer. The caller disposes the queue.
    /// </summary>
    private static Prepared? Prepare(LocalPrintServer server, string? printerName, PaperSize? requestedPaper)
    {
        PrintQueue? queue = null;
        if (printerName is null)
        {
            try { queue = LocalPrintServer.GetDefaultPrintQueue(); }
            catch (Exception e) when (IsPrintSystemError(e)) { return null; }
            if (queue is null) return null;
        }
        else
        {
            using var queues = server.GetPrintQueues([EnumeratedPrintQueueTypes.Local, EnumeratedPrintQueueTypes.Connections]);
            foreach (var candidate in queues)
            {
                if (queue is null && string.Equals(candidate.FullName, printerName, StringComparison.OrdinalIgnoreCase)) queue = candidate;
                else candidate.Dispose();
            }
            if (queue is null) return null;
        }
        var ticket = (queue.UserPrintTicket ?? queue.DefaultPrintTicket).Clone();
        ticket.PageOrientation = PageOrientation.Portrait;
        // The app places every page itself, at real size: the driver is asked not to scale, nor to
        // put several pages on a sheet (the printable area read below is then the one of a whole sheet).
        ticket.PageScalingFactor = 100;
        ticket.PagesPerSheet = 1;
        var caps = queue.GetPrintCapabilities(ticket);
        if (requestedPaper is { } requested
            && PaperSizes.Inches(requested) is not null
            && caps.PageMediaSizeCapability.FirstOrDefault(m => SameMedia(m, requested)) is { } media)
        {
            ticket.PageMediaSize = media;
            caps = queue.GetPrintCapabilities(ticket);
        }
        return new Prepared(queue, ticket, caps);
    }

    /// <summary>A paper size the printer lists is <paramref name="size"/> (<see cref="PaperSizes.Match"/>).</summary>
    private static bool SameMedia(PageMediaSize media, PaperSize size) =>
        media.Width is { } w && media.Height is { } h && PaperSizes.Match(new SizeD(w / 96, h / 96)) == size;

    private static PrinterSetup SetupOf(PrintQueue queue, PrintTicket ticket, PrintCapabilities caps)
    {
        // The paper in inches; a driver that does not say is taken to hold Letter or A4 as usual where the user lives.
        SizeD paper = ticket.PageMediaSize is { Width: { } w, Height: { } h } && w > 0 && h > 0
            ? new SizeD(w / 96, h / 96)
            : PaperSizes.Inches(PaperSizes.DefaultForRegion(AppViewModel.RegionCode))!.Value;
        RectD? printable = caps.PageImageableArea is { } area
            ? new RectD(area.OriginWidth / 96, area.OriginHeight / 96, area.ExtentWidth / 96, area.ExtentHeight / 96)
            : null;
        bool gray = caps.OutputColorCapability.Contains(OutputColor.Grayscale)
                    || caps.OutputColorCapability.Contains(OutputColor.Monochrome);
        bool collate = caps.CollationCapability.Contains(Collation.Collated);
        return new PrinterSetup(queue.FullName, PrinterPaper.Make(paper, printable), caps.MaxCopyCount, gray, collate);
    }
}

/// <summary>
/// The document a print job sends: one paper-sized page per page (every page again for each
/// copy the printer does not make), each image at its <see cref="PrintPlacement"/> in 1/96 inch.
/// Pages are drawn one at a time as the writer asks for them, so a long job never holds every page
/// as a bitmap at once. Also used to write a job to an XPS file (tests).
/// </summary>
public static class PrintDocument
{
    /// <summary>WPF's units per inch.</summary>
    public const double UnitsPerInch = 96;

    /// <summary>
    /// The visual of <paramref name="page"/> on paper <paramref name="paperInches"/>: white,
    /// paper-sized, with the image (turned as placed, in grey for a grey job) at its rectangle. The
    /// XPS writer puts it on a fixed page of the same size. Build on a thread with a dispatcher (an
    /// STA thread).
    /// </summary>
    public static Canvas BuildPage(PrintPage page, SizeD paperInches, bool gray)
    {
        var size = PrintLayout.ToUnits(paperInches, UnitsPerInch);
        var sheet = new Canvas { Width = size.Width, Height = size.Height, Background = Brushes.White };
        var rect = PrintLayout.ToUnits(page.Placement.Rect, UnitsPerInch);
        var pixels = page.Placement.QuarterTurns % 4 == 0 ? page.Image : page.Image.RotatedQuarterTurns(page.Placement.QuarterTurns);
        var image = new Image
        {
            Source = Bitmap(pixels, page.Dpi, gray),
            Width = rect.Width,
            Height = rect.Height,
            Stretch = Stretch.Fill,
        };
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.HighQuality);
        Canvas.SetLeft(image, rect.X);
        Canvas.SetTop(image, rect.Y);
        sheet.Children.Add(image);
        var bounds = new Size(size.Width, size.Height);
        sheet.Measure(bounds);
        sheet.Arrange(new Rect(bounds));
        sheet.UpdateLayout();
        return sheet;
    }

    /// <summary>
    /// The page's pixels as a bitmap of their own (RGB, or 8-bit grey for a grey job), which the XPS
    /// writer stores losslessly. Not a bitmap decoded from a JPEG: the writer keeps one JPEG-backed
    /// picture per document and would print the first page's picture on every page.
    /// </summary>
    private static BitmapSource Bitmap(RgbaImage image, int dpi, bool gray)
    {
        BitmapSource bitmap;
        if (gray)
        {
            bitmap = BitmapSource.Create(image.Width, image.Height, dpi, dpi, PixelFormats.Gray8, null,
                                         ColorAnalysis.GrayPixels(image), image.Width);
        }
        else
        {
            var rgb = new byte[image.Width * image.Height * 3];
            for (int i = 0, o = 0; i < image.Pixels.Length; i += 4, o += 3)
            {
                rgb[o] = image.Pixels[i];
                rgb[o + 1] = image.Pixels[i + 1];
                rgb[o + 2] = image.Pixels[i + 2];
            }
            bitmap = BitmapSource.Create(image.Width, image.Height, dpi, dpi, PixelFormats.Rgb24, null, rgb, image.Width * 3);
        }
        bitmap.Freeze();
        return bitmap;
    }

    /// <summary>
    /// Writes <paramref name="job"/> with <paramref name="writer"/> (a printer's or an XPS file's),
    /// with <paramref name="ticket"/> when given. Runs on the writer's thread, which must run a
    /// dispatcher; cancelling cancels the writer, which drops the job.
    /// </summary>
    public static Task WriteAsync(XpsDocumentWriter writer, PrintJob job, PrintTicket? ticket, CancellationToken token)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var dispatcher = Dispatcher.CurrentDispatcher;
        writer.WritingCompleted += (_, e) =>
        {
            if (e.Cancelled) done.TrySetCanceled(token.IsCancellationRequested ? token : CancellationToken.None);
            else if (e.Error is { } error) done.TrySetException(error);
            else done.TrySetResult();
        };
        writer.WritingCancelled += (_, e) =>
        {
            if (e.Error is { } error && !token.IsCancellationRequested) done.TrySetException(error);
            else done.TrySetCanceled(token.IsCancellationRequested ? token : CancellationToken.None);
        };
        var registration = token.Register(() => dispatcher.InvokeAsync(() =>
        {
            try { writer.CancelAsync(); }
            catch (InvalidOperationException) { done.TrySetCanceled(token); }
        }));
        var paginator = new Paginator(job);
        if (ticket is null) writer.WriteAsync(paginator);
        else writer.WriteAsync(paginator, ticket);
        return done.Task.ContinueWith(t =>
        {
            registration.Dispose();
            return t;
        }, TaskScheduler.Default).Unwrap();
    }

    /// <summary>Draws each page when the writer asks for it.</summary>
    private sealed class Paginator(PrintJob job) : DocumentPaginator
    {
        private Size _pageSize = new(job.Paper.Paper.Width * UnitsPerInch, job.Paper.Paper.Height * UnitsPerInch);

        public override DocumentPage GetPage(int pageNumber)
        {
            // Cancelling goes through the writer (CancelAsync), which stops asking for pages.
            if (pageNumber < 0 || pageNumber >= PageCount) return DocumentPage.Missing;
            var page = BuildPage(job.Pages[pageNumber % job.Pages.Count], job.Paper.Paper, job.Gray);
            var bounds = new Rect(_pageSize);
            return new DocumentPage(page, _pageSize, bounds, bounds);
        }

        public override bool IsPageCountValid => true;
        public override int PageCount => job.Pages.Count == 0 ? 0 : job.DocumentPageCount;

        public override Size PageSize
        {
            get => _pageSize;
            set => _pageSize = value;
        }

        public override IDocumentPaginatorSource? Source => null;
    }
}

/// <summary>Runs print-system work on a thread of its own in the single-threaded apartment, with a dispatcher for the XPS writer.</summary>
internal static class StaWork
{
    public static Task<T> Run<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { done.SetResult(work()); }
            catch (Exception e) { done.SetException(e); }
        })
        {
            IsBackground = true,
            Name = "CompleteScanner print",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }

    public static Task RunAsync(Func<Task> work)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                try
                {
                    await work();
                    done.TrySetResult();
                }
                catch (OperationCanceledException e)
                {
                    done.TrySetCanceled(e.CancellationToken);
                }
                catch (Exception e)
                {
                    done.TrySetException(e);
                }
                finally
                {
                    dispatcher.BeginInvokeShutdown(DispatcherPriority.Background);
                }
            });
            Dispatcher.Run();
        })
        {
            IsBackground = true,
            Name = "CompleteScanner print",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }
}
