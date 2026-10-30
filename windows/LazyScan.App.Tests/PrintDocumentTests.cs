using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Windows.Xps.Packaging;
using System.Xml.Linq;
using LazyScan.App.Services;
using LazyScan.Core;
using Xunit;

namespace LazyScan.App.Tests;

// The print document is what Windows' print path receives: here it is written to an XPS file
// instead of a printer and read back, so the paper size and where each image lands (in 1/96 inch)
// are checked without a printer and without a window. Windows only: no Swift twin (the Mac's print
// document is checked by Tests/LazyScanTests/PrintDocumentTests.swift).
public class PrintDocumentTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("LazyScan-print-tests-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); }
        catch (IOException) { }
    }

    private static readonly SizeD Letter = PaperSizes.Inches(PaperSize.Letter)!.Value;
    private static readonly SizeD A4 = PaperSizes.Inches(PaperSize.A4)!.Value;
    private static readonly XNamespace Xps = "http://schemas.microsoft.com/xps/2005/06";

    private static RectD Whole(SizeD paper) => new(0, 0, paper.Width, paper.Height);

    private static PrintJob Job(SizeD paper, IReadOnlyList<PrintPage> pages, PrintCopiesPlan? copies = null, bool gray = false,
                                RectD? printable = null) =>
        new("Test printer", "Copy", PrinterPaper.Make(paper, printable), null, pages, copies ?? new PrintCopiesPlan(1, 1), gray);

    private static PrintPage Page(int width, int height, int dpi, SizeD paper, PrintMode mode, PrintAlign align, RectD? printable = null,
                                  byte red = 200) =>
        new(RgbaImage.Filled(width, height, red, 40, 40), dpi,
            PrintLayout.Place(width, height, dpi, paper, printable ?? Whole(paper), mode, align));

    /// <summary>Writes the job's document to an XPS file, on an STA thread with a dispatcher, as the print path does.</summary>
    private string Write(PrintJob job, CancellationToken token = default)
    {
        string path = Path.Combine(_folder, $"{Guid.NewGuid():N}.xps");
        RunSta(async () =>
        {
            var xps = new XpsDocument(path, FileAccess.ReadWrite);
            try
            {
                await PrintDocument.WriteAsync(XpsDocument.CreateXpsDocumentWriter(xps), job, null, token);
            }
            finally
            {
                xps.Close();
            }
        });
        return path;
    }

    private static void RunSta(Func<Task> work)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var dispatcher = Dispatcher.CurrentDispatcher;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));
            dispatcher.InvokeAsync(async () =>
            {
                try { await work(); }
                catch (Exception e) { failure = e; }
                finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
            });
            Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Throw(failure);
    }

    /// <summary>One printed page as the XPS file has it: its size, and each image's place and pixels.</summary>
    private sealed record XpsPage(double Width, double Height, List<(RectD Rect, string Resource, int PixelWidth, int PixelHeight, PixelFormat Format)> Images);

    private static List<XpsPage> Read(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        var pages = zip.Entries.Where(e => e.FullName.EndsWith(".fpage", StringComparison.Ordinal))
            .OrderBy(e => int.Parse(Path.GetFileNameWithoutExtension(e.Name), CultureInfo.InvariantCulture))
            .ToList();
        var result = new List<XpsPage>();
        foreach (var entry in pages)
        {
            XDocument page;
            using (var stream = entry.Open()) page = XDocument.Load(stream);
            var root = page.Root!;
            var brushes = root.Descendants(Xps + "ImageBrush")
                .ToDictionary(b => (string)b.Attribute(XName.Get("Key", "http://schemas.microsoft.com/xps/2005/06/resourcedictionary-key"))!,
                              b => (string)b.Attribute("ImageSource")!);
            var images = new List<(RectD, string, int, int, PixelFormat)>();
            foreach (var shape in root.Elements(Xps + "Path"))
            {
                string fill = (string?)shape.Attribute("Fill") ?? "";
                if (!fill.StartsWith("{StaticResource ", StringComparison.Ordinal)) continue;
                string key = fill["{StaticResource ".Length..^1];
                string resource = brushes[key];
                var rect = Bounds((string)shape.Attribute("Data")!, (string?)shape.Attribute("RenderTransform"));
                var (w, h, format) = Pixels(zip, resource);
                images.Add((rect, resource, w, h, format));
            }
            result.Add(new XpsPage(double.Parse((string)root.Attribute("Width")!, CultureInfo.InvariantCulture),
                                   double.Parse((string)root.Attribute("Height")!, CultureInfo.InvariantCulture), images));
        }
        return result;
    }

    /// <summary>The bounds of a path's points ("M0,0L288,0 288,192 0,192Z") after its render transform (a matrix "a,b,c,d,e,f").</summary>
    private static RectD Bounds(string data, string? transform)
    {
        var numbers = data.Split(['M', 'L', 'Z', ' ', ','], StringSplitOptions.RemoveEmptyEntries)
            .Select(n => double.Parse(n, CultureInfo.InvariantCulture)).ToList();
        double[] m = transform is null
            ? [1, 0, 0, 1, 0, 0]
            : transform.Split(',').Select(n => double.Parse(n, CultureInfo.InvariantCulture)).ToArray();
        double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
        for (int i = 0; i + 1 < numbers.Count; i += 2)
        {
            double x = m[0] * numbers[i] + m[2] * numbers[i + 1] + m[4];
            double y = m[1] * numbers[i] + m[3] * numbers[i + 1] + m[5];
            (minX, minY, maxX, maxY) = (Math.Min(minX, x), Math.Min(minY, y), Math.Max(maxX, x), Math.Max(maxY, y));
        }
        return new RectD(minX, minY, maxX - minX, maxY - minY);
    }

    private static (int Width, int Height, PixelFormat Format) Pixels(ZipArchive zip, string resource)
    {
        var entry = zip.GetEntry(resource.TrimStart('/'))!;
        using var stream = new MemoryStream();
        using (var source = entry.Open()) source.CopyTo(stream);
        stream.Position = 0;
        var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
        return (frame.PixelWidth, frame.PixelHeight, frame.Format);
    }

    private static void AssertRect(double x, double y, double width, double height, RectD actual, double tolerance = 0.01)
    {
        Assert.Equal(x, actual.X, tolerance);
        Assert.Equal(y, actual.Y, tolerance);
        Assert.Equal(width, actual.Width, tolerance);
        Assert.Equal(height, actual.Height, tolerance);
    }

    [Fact]
    public void Page_IsThePaper_TheImageAtItsPlace_Lossless()
    {
        // A 3 × 2 in area selected on the glass, centred on Letter.
        string path = Write(Job(Letter, [Page(900, 600, 300, Letter, PrintMode.ActualSize, PrintAlign.Center)]));
        var page = Assert.Single(Read(path));
        Assert.Equal((816.0, 1056.0), (page.Width, page.Height));
        var image = Assert.Single(page.Images);
        AssertRect(2.75 * 96, 4.5 * 96, 3 * 96, 2 * 96, image.Rect);
        Assert.EndsWith(".png", image.Resource);
        Assert.Equal((900, 600), (image.PixelWidth, image.PixelHeight));
    }

    [Fact]
    public void FullPage_AgainstTheCorner_AtRealSize()
    {
        string path = Write(Job(A4, [Page(2480, 3508, 300, A4, PrintMode.ActualSize, PrintAlign.PaperOrigin)]));
        var page = Assert.Single(Read(path));
        Assert.Equal(A4.Width * 96, page.Width, 0.01);
        Assert.Equal(A4.Height * 96, page.Height, 0.01);
        var image = Assert.Single(page.Images);
        // 2480 × 3508 pixels at 300 dpi is 8.2667 × 11.6933 in: 793.6 × 1122.56 units of 1/96 in.
        AssertRect(0, 0, 793.6, 1122.56, image.Rect);
        Assert.Equal((2480, 3508), (image.PixelWidth, image.PixelHeight));
    }

    [Fact]
    public void TurnedPage_IsTurnedInItsPixels()
    {
        // 10 × 7 in across fits Letter only turned.
        string path = Write(Job(Letter, [Page(3000, 2100, 300, Letter, PrintMode.ActualSize, PrintAlign.PaperOrigin)]));
        var image = Assert.Single(Assert.Single(Read(path)).Images);
        AssertRect(0, 0, 7 * 96, 10 * 96, image.Rect);
        Assert.Equal((2100, 3000), (image.PixelWidth, image.PixelHeight));
    }

    [Fact]
    public void FitToPage_IsMadeSmallerInItsPlaceOnly()
    {
        var printable = new RectD(0.25, 0.25, 8.0, 10.5);
        string path = Write(Job(Letter, [Page(3300, 2550, 300, Letter, PrintMode.FitToPrintable, PrintAlign.PaperOrigin, printable)],
                                printable: printable));
        var image = Assert.Single(Assert.Single(Read(path)).Images);
        double height = 11 * 8.0 / 8.5;
        AssertRect(0.25 * 96, (0.25 + (10.5 - height) / 2) * 96, 8.0 * 96, height * 96, image.Rect);
        // The pixels are only turned; the printer scales them into their place.
        Assert.Equal((2550, 3300), (image.PixelWidth, image.PixelHeight));
    }

    [Fact]
    public void CopiesThePrinterDoesNotMake_RepeatTheWholeSet()
    {
        var first = Page(600, 300, 300, Letter, PrintMode.ActualSize, PrintAlign.PaperOrigin);
        // Another colour: the XPS writer stores pictures with the same pixels once.
        var second = Page(300, 600, 300, Letter, PrintMode.ActualSize, PrintAlign.PaperOrigin, red: 40);
        var job = Job(Letter, [first, second], new PrintCopiesPlan(1, 3));
        Assert.Equal(6, job.DocumentPageCount);
        var pages = Read(Write(job));
        Assert.Equal(6, pages.Count);
        Assert.Equal([600, 300, 600, 300, 600, 300], pages.Select(p => Assert.Single(p.Images).PixelWidth));
        // Copies the printer makes itself are not repeated in the document.
        Assert.Equal(2, Read(Write(Job(Letter, [first, second], new PrintCopiesPlan(3, 1)))).Count);
    }

    [Fact]
    public void EveryPageKeepsItsOwnPicture()
    {
        // Two pages of the same size with different content: each prints its own picture.
        static PrintPage Noise(int seed)
        {
            var image = RgbaImage.Filled(600, 300, 255, 255, 255);
            var random = new Random(seed);
            for (int i = 0; i < image.Pixels.Length; i += 4) image.Pixels[i + 1] = (byte)random.Next(256);
            return new PrintPage(image, 300, PrintLayout.Place(600, 300, 300, Letter, Whole(Letter), PrintMode.ActualSize, PrintAlign.PaperOrigin));
        }
        var pages = Read(Write(Job(Letter, [Noise(1), Noise(2), Noise(1)])));
        Assert.Equal(3, pages.Count);
        var resources = pages.Select(p => Assert.Single(p.Images).Resource).ToList();
        Assert.NotEqual(resources[0], resources[1]);
        Assert.NotEqual(resources[1], resources[2]);
    }

    [Fact]
    public void GrayJob_StoresGrayImages()
    {
        var page = Page(600, 600, 300, Letter, PrintMode.ActualSize, PrintAlign.PaperOrigin);
        var gray = Assert.Single(Assert.Single(Read(Write(Job(Letter, [page], gray: true)))).Images);
        Assert.Equal(PixelFormats.Gray8, gray.Format);
        var color = Assert.Single(Assert.Single(Read(Write(Job(Letter, [page])))).Images);
        Assert.NotEqual(PixelFormats.Gray8, color.Format);
    }

    [Fact]
    public void IdCardPage_TheWholePaper_AtItsSize()
    {
        // The composed ID card page is the paper itself, at the page resolution.
        var paper = Letter;
        var (w, h) = IdCardComposer.CanvasSize(paper, 300);
        var placement = new PrintPlacement(Whole(paper), 1, 0, 0);
        var job = Job(paper, [new PrintPage(RgbaImage.Filled(w, h, 255, 255, 255), 300, placement)]);
        var image = Assert.Single(Assert.Single(Read(Write(job))).Images);
        AssertRect(0, 0, 816, 1056, image.Rect);
        Assert.Equal((2550, 3300), (image.PixelWidth, image.PixelHeight));
    }

    [Fact]
    public void Cancelled_TheWriterStops()
    {
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        var job = Job(Letter, [Page(600, 600, 300, Letter, PrintMode.ActualSize, PrintAlign.PaperOrigin)], new PrintCopiesPlan(1, 5));
        Assert.ThrowsAny<OperationCanceledException>(() => Write(job, cancel.Token));
    }
}
