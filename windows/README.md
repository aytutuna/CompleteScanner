# CompleteScanner for Windows

The Windows sibling of the macOS CompleteScanner app, following the **shared core, native
UI per platform** architecture:

- **`CompleteScanner.Core`** — a platform-neutral .NET 10 class library with **zero
  dependencies**: photo detection (thresholding → morphology → connected components →
  convex hull → rotating calipers), the image adjustment pipeline, naming templates,
  presets/settings persistence, a dependency-free searchable-PDF writer, the scanner
  backend contract, scanner problems with their user-facing text (`Troubleshooting.cs`), the
  "Why isn't my scanner listed?" checks (`Troubleshooter.cs`), and the hardware-free demo
  scanner. It is a type-for-type port of the
  Swift `CompleteScannerKit` core (see `../CONTRACTS.md` for the shared conventions,
  especially the four coordinate systems). It also holds the testable protocol logic of the
  Windows-only backends, which has no Swift twin because macOS reaches the same scanners
  through ImageCaptureCore: the WIA error and document-handling tables (`WiaErrors.cs`),
  the eSCL protocol (`Escl/`: capabilities parser, job request builder, 503 retry policy,
  status parser, the HTTP client and session, DNS-SD TXT records and address parsing, and
  certificate pinning for HTTPS), and the TWAIN scan logic (`Twain/`: the acquisition state machine behind an
  `ITwainTransport` interface, memory-strip and bitmap conversion, the paper-size table and
  the condition-code mapping), and the Windows service and network-category values the
  troubleshooter reads (`WindowsSystemStatus.cs`). Device merging (`DeviceMerge.cs`: one row per physical
  scanner, whichever backends list it) is shared with macOS. So is the page clean-up stage
  (`PageProcessor.cs`: the steps every scanned page goes through before it is queued) and the
  image toolkit it works with (`GrayImage.cs`, `BackgroundMap.cs`, `MaskOps.cs` next to
  `RgbaImage.cs`), starting with blank-page detection (`BlankPageDetector.cs`) and crop and
  straighten (`DocumentGeometry.cs`), the ID card task (`IdCard.cs`: finding the card on the
  glass, laying both sides out at real size and drawing the page), copy and print
  (`PrintLayout.cs`: where a page goes on a printer's paper at real size or fitted, copies, the
  ruler test page), text output (`OcrText.cs`: OCR lines in reading order and paragraphs;
  `TextExport.cs`, `DocxWriter.cs` and `ZipStore.cs`: the text file, the Word document and its
  zip package, written by hand so both platforms write the same bytes), receipts
  (`ReceiptProcessing.cs`: finding several receipts on the glass, cleaning up faded thermal
  print, and reading the receipt's date from its text for the `{docdate}` file name), and splitting a
  stack into documents (`DocumentSplitter.cs`; `PatchCode.cs`: separator sheets with patch codes,
  read and drawn for printing; `SavePlan.cs`: several files saved all or nothing).
- **`CompleteScanner.Core.Tests`** — the conformance suite: the macOS test cases ported to
  xUnit with the same fixtures, geometry, and tolerances. **This is the contract that keeps
  the Swift and C# cores behaviorally identical** — change an algorithm on one side, port
  the change, and both suites must stay green.
- **`CompleteScanner.App.Tests`** — checks of the app's own Windows code that need WPF but no
  window and no device: the print document is written to an XPS file and read back (paper size,
  where each image lands, copies, grey, cancel). Nothing is sent to a printer.
- **`CompleteScanner.App`** — the native Windows shell (WPF, .NET 10): main window with
  sidebar/inspector/preview-canvas/page-strip/photo-review, a view-model porting the macOS
  `AppState` orchestration, and Windows service implementations (WIA, eSCL and TWAIN
  scanning, Windows.Media.Ocr, WPF imaging codecs). Its one package dependency is
  [NTwain](https://github.com/soukoku/ntwain) 3.7.6 (MIT), pinned to that exact version, for
  TWAIN.

The macOS app is unchanged and remains the reference implementation.

## Build & run (Windows 10 19041+ / Windows 11)

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0), or Visual
Studio 2026 (18.0+), the first Visual Studio release that supports .NET 10.

```powershell
cd windows
dotnet test                                  # the conformance suite and the app's print-document checks
dotnet run --project CompleteScanner.App     # launch the app
```

The main window has four tabs, like the macOS app:

- **Start** — "What are you scanning?": one card per task (Document to PDF, Multi-page from
  feeder, Photos, Old photo restoration, Quick scan, Email a document, Two-sided document, ID card,
  Copy, Scan to Word, Receipts, Batch of separate documents) and the user's own presets, each badged
  with its task. Picking a card sets everything up for that task, keeps the save folder, fits
  the settings to the connected scanner and opens **Scan**; a card the scanner cannot do (the
  feeder task on a flatbed-only scanner) is greyed out with the reason. On **Scan** a banner
  names the active task and says what to do; **Change task** goes back to Start and the close
  button leaves the task (its settings stay). The task is saved with the settings, so a
  restart comes back to it. A first run opens on Start, later runs on Scan. Each group of
  cards is one Tab stop; the arrow keys move between cards and Enter or Space picks one.
- **Scan** — preview canvas, page queue and the settings inspector (Preview/Scan stay pinned
  at the bottom). Adjustment sliders are centered (-100…+100, 0 = neutral) and preview live
  on the canvas; queued pages can be reordered, rotated 90° or removed; detected photos open
  in a review where each crop can be corrected by hand. **Cancel** works in every busy phase
  (scanning, processing, photo detection, OCR, PDF writing, exports) and never leaves a
  partial file behind.
- **Scans** — this session's scans, newest first; click one to enlarge it.
- **Saved** — the destination folder's files, newest first, with open, share, show-in-Explorer
  and rotate-in-place for JPEG/PNG/TIFF on each card; its **…** button and its context menu
  (right-click, Shift+F10 or the Menu key) add open with, email and copy (see
  [Share, email, open with, copy](#share-email-open-with-copy)).

A scanner that several backends reach (WIA and TWAIN for one USB scanner, WIA and eSCL for
one network MFP) is one row in the sidebar. The app connects through WIA when it can, then
eSCL, then TWAIN; the row's **via WIA ▾** menu chooses another connection for that scanner
(or **Automatic** again). The same menu is the row's context menu (right-click, Shift+F10 or
the Menu key), which is also the way to reach it in the folded sidebar rail; Tab moves from
the selected row to its **via** button. While a scan runs or the photo review is open, a new
choice for the selected scanner takes effect when that ends. The choice is remembered while
the scanner is reached the same ways: it is saved under the network connection's eSCL UUID
when that connection is listed and under the model name otherwise, so a choice made while the
eSCL host answered does not apply while it is offline, and the other way round. Choices for
scanners no longer present stay in `preferences.json`. The names the drivers report, and how
they were matched, are written to `%LOCALAPPDATA%\CompleteScanner\Logs\devices.txt`, so
missing aliases can be spotted on real hardware.

Pick **Demo Scanner** in the sidebar to exercise everything without hardware: scan in
Photos mode to see detection/deskew/review, or Document mode to build a PDF. Its
**Document Feeder (ADF)** source holds three numbered two-sided letter-size sheets (Preview is
for the flatbed, so it is off while the feeder is selected). It scans both sides in one pass,
or, with **Both sides, turned by hand**, the side facing up: it turns its stack over after the
fronts, as the user would, so the next scan delivers the backs, last sheet first. A paper size
makes it deliver sheets of that size. For the **Batch of separate documents** task its feeder holds
seven sheets instead, the third and fifth being separator sheets (the Patch T sheet the app prints,
with a blank back), so the stack splits into documents of two, one and two sheets.

### Two-sided scanning and paper size

The inspector's **Scanner** section has, for scanners with a feeder, **Sides**: **One side**,
**Both sides** (a feeder that scans both sides in one pass) or **Both sides, turned by hand**.
The choice is used while the feeder is the source; on the flatbed it is greyed out with the
reason. On a feeder that scans one side, **Both sides** is greyed out with the reason (and
settings or presets that ask for it are turned into **turned by hand**, with a note), and
turning over by hand is greyed out for photos and when each scan is saved at once, since it
needs the page queue. With both sides, **Flip on** says how the sheets turn: on the **Long
edge** like a book (backs come out upright) or on the **Short edge** like a calendar (backs come
out upside down and are turned upright). **Paper size** (Automatic, then the usual size where
the user lives, Letter or A4, then the others) sets the sheet the feeder is asked for, and on the
glass the area scanned from its corner when nothing is selected on the preview; sizes larger
than the glass or the feeder are greyed out with the reason. Each page in the strip is badged
with its sheet and side ("Sheet 2 · back").

- **Both sides in one pass**: one scan; the pages come front, back, front, back… and are queued
  in that order, the backs turned upright for short-edge sheets. A scanner that falls back to one
  side (its driver refuses two-sided feeding, or its capabilities could not be read on connect)
  says so, and its pages are queued as one-sided pages.
- **Turned over by hand**: a banner guides two steps, **Scan fronts**, then **Scan backs** after
  turning the stack over as a whole. The backs come last sheet first and are put after their
  fronts. When the feeder stops early (a jam) the steps stay at the fronts: the rest of them is
  scanned next, and **Done with fronts** moves on to the backs. A stack larger than the feeder
  holds is scanned a part at a time: **Scan more fronts** goes back to the fronts until the first
  back is scanned. When the counts differ ("3 fronts but 2 backs") the banner says so and offers
  **Combine anyway** (the extra pages at the end), **Scan back sides again** (the backs leave the
  queue) and **Keep fronts only**; scanning again adds the rest of the backs. Without a task the
  banner's close button goes back to one side. Screen readers name each page by its place and
  side ("Page 3, Sheet 2 · back").
- **Two-sided document** task: a 300 dpi PDF of both sides through the feeder; on a feeder that
  scans one side its card says "Both sides, turned by hand" and the task guides the two steps.

The order and orientation of the pages each scanner delivers are decided in Core
(`DocumentSides`) for every connection. **To check on real hardware:** the page order and back
orientation WIA, eSCL, TWAIN and ImageCaptureCore drivers deliver for two-sided scans (front
first, backs not already turned), whether WIA drivers take FRONT_FIRST and the paper size
properties, eSCL feeder regions on center-fed feeders, and TWAIN drivers that discard blank backs
(odd page counts).

### Blank pages

Every document page collected in the queue is checked for being blank as it is scanned
(`BlankPageDetector`, run by `PageProcessor` on the page as scanned, before the adjustments). A
page that looks blank is never removed from the queue: the page strip badges it **Looks blank**
and offers **Skip**. With **Skip blank pages** on (the inspector's **Output** section, under
"Collect pages, then Save PDF") it is dimmed and badged **Blank, skipped** instead, and offers
**Keep**; the button is always shown, not only on hover. Pages are left out only when the queue
is saved, and the status says how many were ("Saved 5-page PDF: … — 1 skipped page was left
out"). A second click on a page undoes the first. The strip's label counts them ("24 pages in
queue, 5 blank skipped"), **Save PDF** counts the pages it will write, and when every page is
skipped it is greyed out and says why. **What counts as blank** sets how much may be on a blank
page: **Low** (nothing at all), **Medium** (the default: dust, show-through or a lone page
number) or **High** (also a few small marks). Pages saved as soon as they are scanned are never
checked or left out, so the switch is greyed out then. The **Two-sided document** task turns
**Skip blank pages** on: the empty backs of one-sided sheets are its main use. The demo scanner's
second sheet has a blank back.

How a page is judged, at 100 dpi whatever the scan resolution: a 0.7 in band along every edge
is left out (edge shadows, staples, punched holes); the paper's brightness is mapped in 0.25 in
tiles (the 90th percentile of each tile, the brightest of its neighbors), so tinted, recycled or
unevenly lit paper is still paper; a pixel is ink when it is darker than 70 % of the paper
around it, which leaves out show-through from the other side and paper texture; marks smaller
than 6 pixels are dust; and the page is blank when the remaining ink covers less than 0.01 %
(Low), 0.03 % (Medium) or 0.1 % (High) of it. A page with a photo, a dark block or a dark band
(more than 1 % of its tiles far darker than the paper) is never blank. Checked here with
synthetic pages (`TestPages`, the same bytes in both test suites) and with public-domain scans
of letters and menus and blank backs made from them (their own paper, their text showing
through at 8–25 %): no letter, menu or photo was taken for blank and every blank back was found.
**To check on real hardware:** blank backs from real duplex feeders, very thin paper with heavy
show-through, and pencil notes on otherwise empty backs.

### Crop and straighten

**Crop to page** cuts each page out of the scanner's background, and **Straighten pages** turns a
page that lies at a slant straight (the inspector's **Output** section, under the blank-page
settings). Both are off unless a task turns them on: the **Two-sided document** task straightens,
since feeders pull sheets in at a slant; no task crops yet. Like the blank-page check they run on
pages collected in the queue only, after the blank-page check and before the adjustments, and a
page saved at once is never changed, so the switches are greyed out then. A changed page carries a
small arrow at its top right in the page strip, always shown, whose tooltip says what was done
("Cropped and straightened 2.4°. Show as scanned."); one click shows the page as scanned, and it
is saved that way, and a second click brings the cropped and straightened page back. Swaps and
the turns clicked behind them run in click order, and **Save PDF** waits for them, on both
platforms. Both versions
are kept in the spool folder (`<id>.png` and `<id>-other.png`), so this works for every queued
page until the queue is saved or cleared. The status after a scan says how many pages were
changed (" 2 straightened.").

How a page is judged, on its gray copy at 100 dpi (`DocumentGeometry`): the scanner's background
is the median of the scan's outer ring (0.03 in); what differs from it by more than 4.5 % (more on
a textured backdrop such as black felt or a dark archive frame) is something on the glass. The
largest such region, with its gaps closed and the inside of its outline filled (a white sheet on a
white lid shows only by its shadow), is the sheet when it covers 15–99 % of the scan, fills at
least 90 % of the rectangle around it, is at most 5 times as long as wide, has no more than 8
text-like marks around it (otherwise it is a picture on a page that fills the scan) and nothing
beside it as large as 2 % of it (another sheet or photo, which cropping would drop). Its edges give
the angle, snapped at full resolution, and the shadow or backdrop left along the edges of the crop
is trimmed (0.04 in at most). A sheet lying along the scan's edge, or no sheet at all, takes its
angle from the lines of text: projection profiles of the ink over ±7°, in 0.5° and then 0.05°
steps, with rows and columns both tried for text running across or down the page. Turns under
0.2° are left alone, a sheet beyond 15° is cropped without being turned, a page with too little
text or no clear line direction stays as scanned, and turning a whole scan never cuts off
anything in its corners (the canvas grows instead).

Checked here on public-domain scans (the archive scans behind the website's pictures). Six of
them (four letters, typed and handwritten, a menu and a menu cover) laid as sheets on a simulated
lid with a contact shadow and on a dark backdrop at -4°, -1.5°, 0.35°, 2.5° and 6° (60 scans at
300 dpi): 45 were cut out and turned by their edges, with an angle error of 0.007° on average
(0.135° at most) and corners within 5 px on average (17 px, 1.4 mm, at most). The other 15 were
not cropped: a white menu on the white lid with its shadow on two sides only, a letter whose own
archive border carries marks around the paper, and a card with a tassel; they were straightened
by their text when it was clear (the print, not the paper: up to 0.27° off the letter's edges and
0.85° off the card's). The menu laid on a lid at 0.35° in the website's bed picture came out at
0.356°. Text skew, measured by turning seven archive scans by a further -3°, -1°, 0.5°, 2° and
5°: 0.056° error on average, 0.35° at most (a menu spread with little text). The archive scans as
captured (white or dark backgrounds, a black frame, a cover strip along one edge) were cropped to
their paper or left alone (a card with a tassel); beds with two or three photos were left alone,
and a bed with one photo card at -4° was cut out at -4.004°.
**To check on real hardware:** shadows from real lids (often on two sides only), feeder scans
with a black or grey backing, and very thin or translucent paper.

### ID card

The **ID card** task (flatbed only; greyed out on a scanner without one) makes a copy of an ID
card or driving licence with both sides on one page at real size. The banner guides three steps:
**Scan front** (the card face down near a corner of the glass, the lid closed), **Scan back** (the
card turned over where it lies; **Skip back side** when nothing is printed there), then the
review. Each scan takes the whole glass (or the area selected on the preview). The card is found among what stands out from the lid
(`PhotoDetector`, things smaller than 1.5 in ignored, four at most): the region closest to an ID-1
card in shape and size (85.60 × 53.98 mm, aspect 1.586; up to a 6 in passport page), else the
largest one, else the whole glass to be cropped by hand; a back that does not stand out (a white
card on a white lid) takes the front's place with its tilt mirrored, moved to the back's
resolution, when both scans cover the same part of the glass (otherwise the largest region or the
whole glass). Each side is cut out and turned straight, and a note says when its crop should be
checked. While a side is held, the inspector's Mode and Source are locked (changing them would end
the task), the app does not switch scanners on its own (a scanner that went away or a better
connection waits until the card is saved or discarded), and leaving the task, picking a task or a
preset asks whether to discard the card first.

The review shows both sides, each with **Turn**, **Fix crop** (the crop editor, on the scan the side
came from) and **Scan again**, **Swap front and back**, and the page they go on: centred, the front
1 in from the top, the back 0.5 in under it, at real size; a side too large for that (a crop fixed
to the whole glass) is made smaller with a warning that the copy is not at real size. **Paper** is
Automatic (the default printer's paper when it holds A4 or Letter, read from Windows; otherwise the
paper usual in the user's region: Letter in the US, Canada, Mexico and the other Letter countries, A4
elsewhere), A4 or Letter; **Save as** is the inspector's format: a PDF page
the size of the paper, or a JPEG, PNG or TIFF of it at the scan's resolution (at most 600 dpi), so
it prints at real size either way; **Also save each side as an image** adds "… front" and "… back" images (JPEG for a
PDF, at the scan's full resolution). The file is named "ID card {date}". Saving is all or nothing.
**Print** prints the page at real size, one copy, on the printer chosen for copies (see
[Copy and print](#copy-and-print)), with no dialog: the sides are laid out on the paper the printer
prints on (the review's paper when the printer has it), and the status says when the printer's
margins reach a card. The review stays open, so the card can still be saved or discarded.

ID cards are sensitive, so the task keeps as little as it can: the scans are never written to the
page spool and never added to the Scans tab, they stay in memory only while the review needs them,
and saving, discarding, leaving the task or picking a task again drops them and clears the preview
on the stage (also a scan whose card was never found, a cancelled one, or a preview of the glass). The PDF gets no searchable text layer unless it is turned on (the numbers on an ID
are better not indexed by search). Files go only to the chosen folder; nothing is sent anywhere,
and the task sets the after-save action to Do nothing. Closing the window with an unsaved card asks first.

The demo scanner has a made-up sample card (ID-1 size, "SAMPLE", a grey photo placeholder and
field bars; a barcode and code blocks on the back) near the top-left corner of its glass, tilted
4°; it turns the card over after each ID card scan.
**To check on real hardware:** light or white cards on a white lid, glossy cards with glare,
cards with holograms, and the real size of a printed copy measured with a ruler.

### Copy and print

The **Copy** task (any scanner; greyed out with "No printer is installed." when Windows lists no
printer) makes the scanner and a printer a photocopier: the main button is **Copy**, which scans and
prints straight away, at real size: a page scanned at 300 dpi prints at its pixels / 300 inches, 1
inch on the glass is 1 inch on paper, and nothing is scaled to the page unless **Fit to page** is on
(then it is made smaller, never larger, to fit the part of the paper the printer prints on, turned a
quarter when that makes it larger, and centred). The inspector's **Copies** section has the
**Printer** (the default printer unless another is chosen; a chosen printer that is no longer
installed falls back to the default, and choosing the default follows the default), its paper,
the **Number of copies** (1 to 99), **Fit to page**, **Also save a PDF** and **Print ruler test
page**; color or grey is the inspector's Color. On the glass with nothing selected and Automatic
paper size, the part of the glass the printer's paper covers is scanned from the corner, as a copier
copies the sheet it prints on; another paper size is asked of the printer too; an area selected on
the preview is centred on the paper; the feeder copies a whole stack. The status says what was sent
("Sent 2 pages to Office Laser, 3 copies.") and what the printer's margins cut off ("Edges may be cut
by up to 5 mm (printer margins).", or "Larger than the paper: …" for a scan larger than the paper);
the inspector says the same before copying. Copies are scanned like any scan (they are in the Scans
tab) but never queued or spooled, so they are printed as scanned: no page is left out as blank,
cropped or straightened (those switches are off for the task, saying so); **Also save a PDF** saves
each copy as "Copy {date} {counter}" after it has gone to the printer, and also when printing failed
(the error then names the PDF), so the scanned pages are not lost; a Cancel while the PDF is written
says the copy was sent and the PDF not saved. Without a printer the section says so and has **Look
again**.

Printing uses System.Printing and the XPS print path, which ship with WPF (no package), and opens no
dialog: `WindowsPrintService` reads the printers (`LocalPrintServer`), takes the printer's own
ticket, portrait at 100 %, asks for the chosen paper when the printer lists it (else prints on its
own paper and lays the page out on that), lets the printer make the copies (collated) when its
capabilities say it can make that many and, for several pages, that it collates, and otherwise puts
the pages in the job that many times; whatever the printer's saved preferences say, the job sets its
copy count, one page per sheet, one-sided printing, and grey output for a grey or black-and-white scan or colour for a
colour one (`WindowsPrintService.ApplyJobSettings`), and writes one paper-sized page per page
with the image at its place in 1/96 inch, each page drawn only when the writer asks for it. The page
images are stored losslessly as plain bitmaps: the XPS writer keeps a single picture for every
JPEG-backed bitmap in a document, so JPEG frames would print the first page on every page. Cancel
cancels the writer, which drops the job. The printer list, the default printer's paper and its
printable area are read when the app starts, when the window comes back to the front, when the
start screen is shown, when the Copy task is picked, when the printer list is opened and with **Look
again**; reading never changes a printer or its settings. A print system that cannot be read (the
Print Spooler stopped, say) is not taken for "no printer": the Copy task stays offered.

**Print ruler test page** prints a page with a grey 1-inch grid from the paper's corner and black
centimetre ticks along the first inch line (longer every 5 cm), at real size, to measure with a
ruler.
**To check on real hardware:** a real printer's margins and whether a driver offsets the page by its
margin (measure the ruler page), copies and collation, grey output, and drivers that do not report
an imageable area.

### PDF size

The inspector's **Output** section has a **PDF size** choice for PDF output: Best, Standard,
Compact or Smallest, with a line under it saying what the chosen size does and how big the
last saved PDF was (the status bar names the size too). `PdfImageEncoding` plans each page:

| Size | Page images at most | JPEG quality (color / gray) | Color pages without color |
|---|---|---|---|
| Best | scan resolution | 0.90 / 0.90 | stay color |
| Standard | 300 dpi | 0.80 / 0.80 | stored gray |
| Compact | 200 dpi | 0.65 / 0.70 | stored gray |
| Smallest | 150 dpi | 0.50 / 0.55 | stored gray |

Pages are downsampled (box filter) only when they are more than 10 % finer than the limit;
the page size in the PDF never changes, and text recognition reads the full-resolution page
first. Grayscale and black & white pages are stored as one-component JPEGs (`/DeviceGray`). A
color page counts as having no color when fewer than 0.1 % of its sampled pixels (every 4th
pixel of every 4th row) differ by more than 32 between their strongest and weakest channel,
so a stamp or a highlighter mark keeps the page in color. The size alone sets the JPEG
quality of PDF pages; the JPEG quality setting (stored in the settings file, no control on
Windows) applies to JPEG files only, as before. The **Email a document** task scans at 300 dpi,
saves Compact and then opens the share window.

**Behavior change:** Standard is the default for everyone, including existing settings and
presets, which have no size stored; earlier versions always wrote full-resolution RGB JPEGs
at quality 0.9 (Best gives that again, except that gray pages are now stored gray). A size
written by a newer version reads as Standard.

Measured on two public-domain document scans (a 1903 letter on aged paper with purple
typewriting and a red logo, 2673 × 3500 px; a 1900 menu on white paper with a blue stamp and
pencil notes, 2550 × 3510 px), both saved as 300 dpi one-page PDFs through the app's save path:

| Page | Color mode | Before | Best | Standard | Compact | Smallest |
|---|---|---|---|---|---|---|
| letter | Color | 1.17 MB | 1.17 MB | 856 KB | 259 KB | 119 KB |
| letter | Grayscale | 1.11 MB | 1.07 MB | 778 KB | 263 KB | 111 KB |
| letter | Black & White | 694 KB | 655 KB | 527 KB | 216 KB | 122 KB |
| menu | Color | 1.48 MB | 1.48 MB | 905 KB | 309 KB | 160 KB |
| menu | Grayscale | 1.40 MB | 1.36 MB | 833 KB | 314 KB | 157 KB |
| menu | Black & White | 997 KB | 956 KB | 760 KB | 309 KB | 183 KB |
| menu with its color removed, scanned in color | Color | 1.40 MB | 1.40 MB | 833 KB | 314 KB | 157 KB |

Both real pages have color, so they stay color; the last row shows a color scan of a page
without color being stored gray. Black & white pages are still JPEGs; CCITT G4 (a later
step) would make them far smaller.

### Share, email, open with, copy

After every save a green bar above the window names what was saved (the PDF's size too) and
offers **Open**, **Show in folder**, **Share** and **Copy**; its **…** button adds **Open
with…** and **Email…**. With several files (a batch of photos) Open and Open with are left out.
The bar goes away with its close button or when the next scan starts; in narrow windows its
buttons show only their icons (names stay in tooltips and for screen readers). The Saved tab's
cards offer the same actions. Nothing leaves the PC without the user choosing where it goes:

- **Share** opens the Windows share window (the SDK's `DataTransferManagerInterop` for desktop
  windows), which lists Mail, Outlook, nearby sharing and other apps. The files are offered as
  read-only copies. Where Windows has no share window, the files are shown in their folder with
  a note instead.
- **Email** opens the same share window: pick Mail or Outlook there. The app does not use
  Simple MAPI or `mailto:` (the new Outlook does not support Simple MAPI, and `mailto:` cannot
  attach files), and it never writes a message or an address itself.
- **Open with…** is the Windows "Open with" dialog for the file.
- **Copy** puts the files on the clipboard (pasting into a folder copies them); for one image
  file its picture goes on the clipboard too, for pasting into a document or an image editor.

**After saving** (in the inspector's Output section, and next to the photo review's Save
button) runs one of these on its own once a save has finished: **Do nothing** (the default),
**Open**, **Show in folder** or **Share…**. Several files are shown in their folder rather than
opened one by one. A cancelled or failed save runs nothing, and a file that has been moved or
deleted since is reported instead. Picking a task sets it: the **Email a document** task shares,
the others do nothing. The choice is decided in Core (`SaveActions`: the plan, the actions
offered, what Copy puts on the clipboard, the email route) and carried out by
`Services/FileActions.cs` and `Services/ShareService.cs`, which the view model takes as a
stand-in in checks.

### Text: Word documents, text files and Copy Text

For editable text rather than a picture of the paper:

- **Format** (inspector, Output) offers **Word (.docx)** and **Text (.txt)** for documents, next
  to PDF and the image formats; Photos offers the image formats only (a PDF or text format chosen
  for documents shows as JPEG there and is kept). With the pages collected, the queue's button
  becomes **Save Word** or **Save Text** and writes one file with the text of every page; a scan
  saved at once is written as its own Word document or text file. The ID card's page is a PDF or
  an image whatever the format says.
- **Also save text (.txt)** (inspector, Document) writes a text file with the PDF's name next to
  every PDF of a document saved (the next free name when that one is taken; nothing is ever
  replaced). It is greyed out, with the reason, when a save writes no PDF, and in the ID card and
  Copy tasks, whose PDFs are pictures of a card or of a copy. Picking a task turns it off.
- **Scan to Word** on the start screen: 300 dpi, color, pages collected, saved as a Word
  document. Choosing another format ends the task.
- **Copy text** in a queued page's right-click menu reads that page and puts its text on the
  clipboard (Windows line breaks, a blank line between paragraphs). The page stays queued.

OCR reads each page once per save, on the full-resolution page with its rotation: the same
lines make the PDF's text layer and the text file beside it, and nothing is read when neither is
asked for. When a page cannot be read (no OCR language installed), a Word or text save fails
with "The text could not be read: no OCR language pack is installed (Settings → Time & Language
→ Language).", the pages stay queued (a scan saved at once goes to the queue, as does one whose
file cannot be written or whose save is cancelled, so it can be saved once the text can be read
or the destination is back, or as a PDF; the status says to wait for the text only when the text
was what failed), and the
troubleshooter does not count it as a scanner failure; a PDF is still saved, without its text
file ("The PDF was saved, but not its text file: …"). A page with no text gives an empty file, and the status says no text was found.

The files (`TextExport`, `DocxWriter`, `ZipStore`): the text file is UTF-8 without a byte order
mark, "\n" line breaks, one line of text per line on the page, a blank line between paragraphs
and two between pages. The Word document is the smallest package Word and LibreOffice open
(`[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, stored uncompressed in a zip dated
1980-01-01): one Word paragraph per paragraph found, wrapped lines joined (a word broken by a
hyphen at the end of a line joined again), short lines and the rows of a table kept on lines
of their own (`w:br`), the pieces of a row separated by tabs, each page after the first starting
a new page, the paper the first page's size with one-inch margins (less on a page under 8
inches), and no styles part, so the text takes the reader's default font.

**Reading order** (`OcrText`): the OCR engine's own order is not a reading order. On the
public-domain 1903 letter (2673 × 3500 px) Windows OCR returns 41 lines with the letterhead's
list of officers before the small print beside it but "Honorable" among them, fourteen lines
before "Charles G. Washburn,", and "Mass." between "August" and "31,"; it also splits rows such
as "The full list is as follows:" | "General Rockwood Hoar;". The page is therefore cut along its empty
gaps (a recursive X-Y cut): first a wide gap across the page (1.5 line heights), then a gap down
the page (2 line heights) between two columns of text, then any gap across. Two sides that pair
up row by row with a gap at least as wide as the narrower side's lines are a table and are read
row by row; lines of one row become one line, with a tab across a wide gap. Paragraphs start
at a jump up to the next column, at a gap clearly wider than the usual gap around it, at a left
edge that moves by a fifth of the page, and at an indented line; lines centred on each other (a
letterhead) stay together. Results on the two public-domain scans used for the PDF sizes,
through the app's save path with the OCR installed here:

- **Letter**: 41 OCR lines become 36 lines in reading order and 14 paragraphs: the title, the
  officers (one paragraph), the small print, the office's address, the date, the three address
  lines, the salutation, the three body paragraphs (indented first lines) and the two closing
  lines. "forward-" / "ing" is joined in the Word document. What is still wrong comes from the
  recognizer, not the order: "Ily dear Sir:-", "1003" for 1903, "l!orcester", "Worce ster", "Rea
  Cross"; the signature and the pencilled notes are not read.
- **Menu** (1900, three columns of dishes and prices under section headings, a library stamp and
  pencilled notes): 95 OCR lines become 65 lines: every heading before its section, the sections
  in order, each read row by row with the dishes of one row on one line, tab-separated ("Wahl's
  Vegetable Bouillon, 15c → Soup without Meat or Fish order, 15"). Windows OCR itself joins two
  dishes into one line in two places, and the stamp garbles the dishes under it ("Prime Bee ,
  .t"); the handwritten heading is not read.

A two-column page whose columns sit closer than two line heights, or a page in two columns with
paragraph breaks that line up across both, is read across the columns; the engine's order is
used only to break ties.

### Receipts

The **Receipts** task (start screen) scans several receipts at once into small files named by
their date: 300 dpi, grayscale, Compact PDFs, searchable, named `Receipt {docdate} {counter}`.

- **Finding them** (`ReceiptDetector`): on the scan's 100 dpi gray copy, the marks that differ from
  the lid by more than 9 % (print, and paper edges with some contrast) are run together into
  blocks (0.12 in closing); blocks one above the other less than 0.6 in apart are one receipt, and
  a block too small to be a receipt (a column of prices) joins the receipt next to it, or beside
  it up to 1.5 in away. Where the paper itself shows (a dark lid, or paper a few levels off a white
  one), blocks on different sheets are never joined and a column of prices joins the receipt on
  its own sheet. Around each receipt the paper is looked for as a sheet with the page search of
  crop and straighten, held to receipt limits only for this task: 2 % contrast instead of 4.5 %
  (thermal paper on a white lid), 85 % fill instead of 90 % (curled edges), and up to 15 times as
  long as wide instead of 5. When the paper holds all the print the receipt is cut along it;
  otherwise (paper as light as the lid) it is cut around its print at the angle of its lines of
  text, with 0.08 in of margin. A receipt is at least 0.5 × 1 in; at most 12 are taken. From the
  feeder each sheet is one receipt.
- **Cleaning up** (`ReceiptEnhancer`): gray; the paper's brightness measured in 0.25 in tiles (90th
  percentile, the brightest of each tile and its neighbours, never far below the middle tile so a
  dark logo stays dark); each pixel divided by the paper there, the darkest print (1st percentile,
  at most 0.6) stretched to black and 0.9 of the paper to white, then darkened with a power of 1.6.
  Faded print at 0.62 on paper fading from 0.95 to 0.80 comes out at 0.6 or darker on white.
- **Review**: the photo review, titled "Found 3 receipts", with Keep, turn and Fix crop (a
  receipt is cut out upright and cleaned up again). **Save 3 Receipts**, or **Save as One PDF**
  with **One PDF for all receipts** (inspector, Receipts).
- **Saving**: each receipt is read with Windows OCR once, as shown (turned), when its date, a
  searchable PDF or the text beside it needs it; the same lines are the PDF's text layer and the
  .txt with **Also save text**. A file each is named by its receipt's date; one PDF for all by the
  earliest; today's date when no date is found ("No date was found on 1 of them; it is named by
  today's date."; for one PDF only when no receipt had a date). The date is read only when the
  naming template has `{docdate}`. A receipt whose text cannot be read is still saved, without a
  text layer. JPEG, PNG and TIFF save each receipt as an image (one PDF is then not offered); Word
  and text are not offered for receipts (a Word or text format left from before saves PDFs, and the
  format box shows PDF). All or nothing:
  a failed or cancelled save removes what it wrote and the review stays open.
- **The date** (`ReceiptDateExtractor`): numeric dates (2026-03-12, 2026/3/5, 12/03/2026,
  03/12/2026, 12.03.2026, 12-03-26), month names and their abbreviations in English, Turkish,
  German, French, Spanish, Italian, Portuguese and Dutch (12 Mar 2026, Mar 12, 2026, 12-MAR-26,
  12 Mart 2026, 12. März 2026, 12 de marzo de 2026), and 2026年3月12日 / 2026년 3월 12일. A date
  must exist and lie between ten years ago and tomorrow, which rules out times, phone numbers,
  amounts and card expiry dates (two-digit years are this century). Day or month: a part above 12
  is the day; dots (12.03.2026) put the day first; otherwise the user's region decides (the short
  date pattern of the current culture). The first date on a line that says Date, Datum, Tarih,
  Tarihi, Fecha, Data, Dated or Issued wins; otherwise the first date in reading order, leaving out
  lines about validity (Exp, Expiry, Valid, Until, Gültig, Son kullanma, SKT, Best before, Use by,
  Return by). A month name is read only where it stands: "Table 4 Sat 18 Apr 2026" is 18 April.
  On the test set of 99 receipts and lines (`ReceiptDateCases`, mirrored in Swift) it
  reads every case of the formats above as a person reads it, rejects every non-date, and misses 3
  of 5 OCR-noise cases: letters read for digits (2O26) and spaces inside a date (12 / 03 / 2026)
  are not repaired.

The demo scanner holds two made-up receipts for the task ("DEMO CAFE" and "SAMPLE MART", thermal
paper at 0.93 with print at 0.6, tilted 3° either way), printed in a plain stroke type that Windows
OCR reads, with a date each (12.03.2026 and 2026-02-27): the files come out as "Receipt
2026-02-27 …" and "Receipt 2026-03-12 …".

### Batch of separate documents

**Split into documents** (the inspector's **Output** section, under the crop and straighten
switches) saves the collected pages as several files: **At separator sheets**, **At blank sheets**
or **Every N sheets** (with **Sheets per document**, 1 to 99 in the list, up to 999 in a settings
file). The **Batch of separate documents** task (feeder only; greyed out on a scanner without one)
sets it up: 300 dpi, PDF, split at separator sheets, blank pages skipped, named
`Document {label} {date} {counter}`. The other tasks do not split; the sheets per document are
kept. Like the blank-page check, splitting needs the pages collected in the queue, so the choice is
greyed out, with the reason, when each scan is saved at once, for copies and for receipts.

- **Separator sheets**: **Save separator sheet (PDF)** (shown with At separator sheets) saves a
  Patch T sheet as a one-page PDF in the scans folder, "Separator sheet (Patch T, Letter).pdf" or
  A4 where that is the usual paper, to print at actual size (100%) on any printer, also on another
  computer; it needs no printer here, and the saved bar opens it. **Print separator sheet** prints
  the same sheet at once, at real size, with no dialog, on the printer chosen for copies and on the
  paper that printer has (whatever paper size the scan asks for). The sheet: the four bars of the
  code across the sheet 1 in from the top and again, turned half a turn, 1 in from the bottom, so it
  reads the same fed either way round, and the words "SEPARATOR SHEET", the code and how to use and
  print it between them. Any patch code counts, also one printed by other software, read either way
  round (1 and 6, 3 and T read backwards are each other) and at a slant of a few degrees; the whole
  sheet, both sides, is left out.
- **Blank sheets**: one-sided, every blank page splits; with both sides scanned only a sheet blank
  on both sides does, so the blank back of a one-sided page is no separator (it follows Skip blank
  pages). One-sided, Skip blank pages has no say, so the switch is greyed out and says why. Several
  separators in a row split once, and a document with nothing in it is not saved.
- **Every N sheets**: a sheet is a front with its back; blank sheets count too.

Nothing is split unseen. The page strip shows the plan before saving: the first page of each
document is badged "Document 2" (with its name, "Document 2 · Lease"), a bar in the gap before it;
separator pages are badged **Separator**, dimmed, with **Keep**, which saves the page and stops
its sheet from splitting (a second click undoes it); the gap before every other page is a button
(shown while a split is chosen or the queue is split): one click starts a new document there, one
click on a document's bar joins it to the document before, and a second click undoes either. A
page's right-click menu has the same split or join, also without a split chosen, and **Name this
document…**, which opens a small box over the page: the name is `{label}` in the file name (Enter
keeps it, Esc cancels, an empty name removes it; up to 100 characters, and the file name takes at
most 120 bytes of it, cut between characters). The name stays with its document: when its first
page is skipped (or a page before it is kept again) the name moves to the document's new first
page, and a document that is gone and comes back has its name back. Moving, turning or removing
pages keeps every page's facts, and the plan follows the queue as it is. The strip's label counts the documents and
what is left out ("7 pages in queue, 3 documents, 2 separator pages skipped"), the status after a
scan says what was found (" Found 2 separator pages: 3 documents to save."), and the save button
says what it writes: **Save 3 PDFs (5 pages)**.

Saving writes a file per document, each with its own counter and the document's number as
`{index}` (added at the end when the template has no `{index}`, as for a batch of photos), its text
beside it with **Also save text**, or a Word document or text file each for those formats. It is all
or nothing (`SavePlan`): a failure or Cancel part-way removes every file it wrote, text files too,
and the queue stays as it was ("None of the documents was saved; the pages are still in the
queue. …"), and the inspector's last PDF size is the one from before. Afterwards the status names
the files, their size together, the text files beside them, Word or text files with no text found,
and what was left out ("Saved 3 PDFs (5 pages, 256 KB): … and their text, … — 2 separator pages
were left out"). A queue that is one document saves as before.

How a patch code is read (`PatchCodeDetector`), on the page's gray copy at 100 dpi, after crop and
straighten, on every page collected in the queue whatever the split, so a split chosen later finds
them: along each column (and each row, for bars down the page) the ink, darker than half the paper,
gives runs; four in a row match when each is narrow (0.05–0.12 in) or wide (0.15–0.26 in), exactly
two are wide, the gaps are 0.05–0.12 in and nothing is printed for 0.3 in on either side; matches on
neighbouring lines with the same code, moving by at most 0.02 in from line to line, are one code,
which counts when read over at least 1.5 in on at least half the lines it spans. Checked on
synthetic pages (`TestPages`, the same bytes in both test suites): all six codes across and down the
page, at ±2.5° and ±3°, the separator sheet at 100 and 300 dpi, turned half and a quarter turn, and
no code found on pages of text, a ruled table with a header band and striped rows, blank pages,
photos and a sheet on a backdrop. Barcode and QR separators need a barcode library and come later.
**To check on real hardware:** separator sheets printed on real printers (toner spread, a printer
that shrinks the page), feeders that skew sheets more than 3°, and very dark or colored paper.

### Why isn't my scanner listed?

The **?** button next to **Scanners**, the link under the scanner list while only the Demo
Scanner is listed, and **Troubleshoot** on an error about a scanner that would not connect or
scan open a window of checks, each a card with its status (problem, warning, OK or tip), what it
means in plain language and the buttons that help:

- **The last failure**: a scanner that is busy in another app ("close other apps that may be
  using it, such as Windows Scan or the scanner maker's app"), another condition the scanner
  reported (the `ScannerProblem` texts: cover open, jam, offline, …), or a connection that failed,
  with its message.
- **The network**: not connected, or connected only to networks whose profile is **Public**, where
  Windows does not look for devices (**Open network settings**, **Add scanner by address…**).
- **The Windows scanner service**: Windows Image Acquisition (`stisvc`) running, starting, stopped,
  disabled or missing, read with `QueryServiceStatus` and `QueryServiceConfig` (read-only access).
- **TWAIN**: installed with how many drivers, not installed (a warning while no scanner is listed,
  a tip otherwise), or would not start; and drivers installed only for 32-bit apps, named by file.
- **The automatic network search** (DNS-SD) and how many scanners it found, and each address
  added by hand that does not answer, with why.
- **Tips** that always apply: a USB scanner needs its maker's driver and a direct cable
  (**Open Windows scanner settings**, `ms-settings:printers`, shows whether Windows sees it);
  wake the scanner; some scanners work only with their maker's app.

**Refresh** asks every connection to look again: WIA lists its scanners, eSCL checks the addresses
added by hand and restarts a network search Windows had stopped (only the stopped one; the scanners
it had found stay listed, and those its new search does not find again are dropped after its first
pass), and TWAIN lists its drivers again when it was missing or would not start (while TWAIN works
its list stays as it is). A Refresh while one is running is ignored. The checks are made again as
the scanner list changes. **Copy diagnostics** copies the checks and the device list
(the same text as `%LOCALAPPDATA%\CompleteScanner\Logs\devices.txt`, which now ends with the
checks). The window only reads: it never starts, stops or reconfigures a service or a setting, and
the Settings buttons only open Windows Settings. Everything is keyboard reachable (Tab goes through
each card's buttons in reading order; Enter or Esc closes), and screen readers hear each card's
status with its title (each card is a group named that way, and each button's help text says the
same). The checks are made in Core (`Troubleshooter.Diagnose` over a
`DiscoverySnapshot`, with the same cases and wording as the Mac); each connection adds what it
knows through `IScannerBackendDiagnostics`, and the system's state comes from
`Services/SystemDiagnostics.cs` (the Network List Manager for the network category).

## Status — what's verified vs. what needs scanner hardware

| Component | Status |
|---|---|
| Build | Builds on Windows 11 with the .NET 10 SDK |
| Core algorithms (detector, geometry, pipeline, naming, PDF) | Ported line-by-line from the tested Swift originals; **`dotnet test` passes** (the conformance suite mirroring the macOS tests) |
| Demo scanner + WPF shell | **Verified on Windows 11:** the app launches and connects to the Demo Scanner; driving the view-model, Photos-mode scans detect, re-crop and save the demo photos, Document-mode scans queue, rotate and save a multi-page PDF (with the OCR pass), cancelled scans/OCR/PDF saves leave no files, and scan history fills. All three tabs, the photo review and the crop editor were checked on screen (including the 700×560 minimum window); a hands-on interactive walkthrough is still to do |
| Windows OCR (`WindowsOcrService`) | **Verified on Windows 11** against rendered text (line boxes come back in the bottom-left-origin Core convention); needs a language pack installed |
| WIA backend (`WiaScannerBackend`) | **Experimental, untested against hardware** — documented WIA Automation flow; enumeration runs off the UI thread and re-polls (every 10 s backing off to 60 s while no scanner is present, every 60 s while one is), so scanners plugged in or unplugged later show up without a restart. The sources come from the device's document-handling capabilities, so a feeder-only scanner offers no flatbed and no preview; the feeder's sheet size and two-sided support are reported; two-sided feeder scans select FEEDER, DUPLEX and FRONT_FIRST (without FRONT_FIRST for a driver that refuses it, the feeder alone, one side, for a driver that refuses two-sided feeding, which the app is told) and every sheet (`WIA_DPS_PAGES` 0); a driver that takes no feeder selection at all scans the feeder only when it is already selected (single-source drivers can make the selection read-only), with the sides it has selected, and otherwise fails rather than scanning another source; a feeder paper size is set through `WIA_DPS_PAGE_SIZE` (the custom size and width/height for sizes WIA has no name for) and the item's extents; a feeder batch uses one connection; WIA error codes become plain messages (an empty feeder says "Load paper in the feeder, then scan again."); a batch that fails partway keeps the sheets already scanned and tells the user how many were kept and why it stopped. Expect to iterate with a real scanner attached |
| Task start screen (`TaskCatalog`, `TaskFlow`, `SettingsAdapter`) | Covered by `ScanTaskTests`, `TaskFlowTests`, `SettingsAdapterTests` and the task cases in `ModelsCompatTests` (same cases as macOS). Checked by driving the view model with the demo scanner and fake flatbed-only and feeder-only scanners (each task's settings, scans and file names, the task ending when the mode is changed by hand or the scanner lacks its source, the reasons on unavailable cards, presets and scanner switches going through `SettingsAdapter`, the task coming back after a restart), and by building the window without showing it: tabs, cards, banner, keyboard navigation, screen-reader names and the banner's announcements of the task and of each new step, rendered off screen in light and dark |
| PDF sizes (`PdfImageEncoding`, `ColorAnalysis`) | Covered by `PdfImageEncodingTests`, `ColorAnalysisTests`, the gray-JPEG cases in `PdfBuilderTests` and the size cases in `ModelsCompatTests` and `ScanTaskTests` (same cases as macOS). Checked by driving the view model's real save path with two public-domain document scans in every color mode and size (image size and color space as planned, page size unchanged, every PDF renders through Windows.Data.Pdf close to the scan, sizes shrink in order; see [PDF size](#pdf-size)) and by building the window without showing it: the size control, its hint and last-size line, hiding it for other formats and Photos, the Email card, rendered off screen in light and dark |
| One row per scanner (`DeviceMerge`, connection chooser) | Matching rules, ranking and the saved choice are covered by `DeviceMergeTests` (same table as macOS) and were checked by driving the view model with fake WIA and TWAIN backends: one row, WIA preferred, a later-appearing better connection taken over once the running scan ends, the user's choice saved and used at the next start, a choice made during a scan applied after it. A saved choice is keyed by the eSCL UUID or the model name, whichever the current set of connections yields, so it lapses when that set changes (see above). **Unverified with real drivers:** the names real WIA, eSCL and TWAIN drivers report; `devices.txt` collects them |
| TWAIN backend (`Scanning/Twain`) | **Experimental, untested against hardware** — see [TWAIN](#twain) below. The scan logic in Core (negotiation choices, the acquisition state machine, strip and bitmap conversion, paper sizes, error mapping, 32-bit driver detection) is covered by `TwainScanLoopTests`, `TwainRasterTests` and `TwainScanRequestsTests` through a fake transport. Driving the view model with the real session class over a scripted transport checked flatbed, feeder, preview, empty feeder, a jam after two sheets (pages kept, reason shown), cancel while the driver is silent (returns at once, the source is reset and disabled in the background), switching away (the source is closed without waiting), the driver-window switch and its saved choice (kept when connecting finds the scanner off), a driver stuck while enabling (reported after the start limit, the next scan refused at once, the late scan stopped when the driver answers), and that a scanner only TWAIN lists is never opened unless the user picks it. On a PC without a TWAIN Data Source Manager the backend lists nothing and `devices.txt` says why; the app starts normally. **Unverified:** real drivers, NTwain's message loop with them, the TWAIN Working Group sample source (not installed here) |
| Two-sided scanning and paper size (`DocumentSides`, `PaperSize`) | Covered by `DocumentSidesTests`, `PaperSizeTests` and the sides cases of `ModelsCompatTests`, `ScanTaskTests`, `SettingsAdapterTests` and `MockScannerTests` (same cases as macOS), plus the backend requests in `EsclTests`, `TwainScanRequestsTests` and `WiaErrorsTests`. Checked by driving the view model with the demo scanner (both sides in one pass on the long and the short edge, a jam keeping one sheet's two sides, turning over by hand with matching counts, a mismatch, scanning the backs again, combining anyway, keeping the fronts, a jam during the fronts (the steps stay at the fronts, the rest of them scanned as fronts, Done with fronts), a stack scanned in parts (Scan more fronts), a scanner whose capabilities could not be read on connect asked for both sides by a one-sided feeder (pages kept one-sided, capabilities read after the scan), earlier pages keeping their place, the two-sided task on two-sided and one-sided feeders, paper sizes on the feeder and the glass, the saved PDFs' page counts) and by building the window without showing it: the Sides, Flip on and Paper size choices with their greyed-out items and reasons, the banner's two steps, Scan more fronts, Done with fronts and the mismatch choices, the side badges and the screen reader names in the page strip and the Two-sided document card, rendered off screen in light and dark. **Unverified:** real drivers (see [Two-sided scanning and paper size](#two-sided-scanning-and-paper-size)) |
| Crop and straighten (`DocumentGeometry`, `GeometryStep`, `PageCorrections`) | Covered by `DocumentGeometryTests`, the crop and straighten cases of `PageProcessorTests`, `ModelsCompatTests`, `ScanTaskTests` and `MaskOpsTests` (same cases as macOS, on the same synthetic pages checked by checksum). Checked on public-domain scans laid at known angles on a lid and a dark backdrop, on archive scans as they were captured, and by driving the view model with those scans (scan, the strip's captions, both versions spooled, show as scanned and back, turning a page, saving whichever version is shown, removing and clearing pages, the switches off and pages saved at once, the two-sided task) and by building the window without showing it: the switches and their hint, the swap button and its glyphs, rendered off screen. **Unverified:** real lids, feeder backings and thin paper (see [Crop and straighten](#crop-and-straighten)) |
| ID card (`IdCard`, the review) | Covered by `IdCardTests` (paper, steps, layout on Letter and A4, scaled to fit, the composed page in pixels and as a 612 × 792 pt PDF page, the detector on a synthetic bed with a card turned 7° among other objects, the back taking the front's place, moved to another resolution and refused for another part of the glass, the page at most 600 dpi, Skip only for the card's back) and the ID card cases of `ScanTaskTests`, `ModelsCompatTests`, `TaskFlowTests` and `MockScannerTests` (same cases as macOS). Checked by driving the view model with the demo scanner's sample card (front, back, the review, turning and swapping the sides, fixing a crop, Letter and A4, saving a PDF at 612 × 792 pt with no text layer, a PNG page at 300 dpi with the front as an image, skipping the back, scanning a side again, discarding, leaving the task, picking a task again) and with a white-on-white back (at the front's resolution, at twice it, and with another selection), a scanner going away with the review open and between the sides (no switch until the card is saved, discarded or the task left), a page saved from a 1200 dpi scan (A4 at 600 dpi, the side at 1200), the stage cleared on leaving with no side held, checking that nothing goes to the history or the page spool and that the stage is cleared, and by building the window without showing it: the task card, the banner's steps and Skip back side (and no Skip for the backs of a stack turned over by hand), Mode and Source locked while a side is held, Leave the task and picking a task asking first (Cancel keeps the card, Discard drops it), the review with both sides, the front only, the not-at-real-size warning, the paper and format pickers, rendered off screen in light and dark. **Unverified:** real cards on real lids (see [ID card](#id-card)), printing at real size |
| Blank pages (`BlankPageDetector`, `PageProcessor`, `PageFilter`, image toolkit) | Covered by `BlankPageDetectorTests`, `PageProcessorTests`, `GrayImageTests`, `RgbaImageTests`, `MaskOpsTests` and the blank-page cases of `ModelsCompatTests`, `ScanTaskTests` and `MockScannerTests` (same cases as macOS; `MaskOpsTests` also pins PhotoDetector's regions on the demo bed to the last bit, unchanged by moving the mask code out of it). Checked on public-domain scans of letters, menus and photos (none taken for blank, at any level, with or without their dark surroundings) and on blank backs made from them (all found blank), and by driving the view model with the demo scanner (flagging, Skip blank pages turned on and off with pages queued, Keep and Skip per page, rotating a flagged page, saving 5 of 6 pages, nothing to save, pages saved at once keeping every page, the two-sided task, turning over by hand) and by building the window without showing it: the switch, the levels, the badges, Keep and Skip, the strip label, Save PDF's count, rendered off screen in light and dark. **Unverified:** blank backs from real scanners (see [Blank pages](#blank-pages)) |
| Copy and print (`PrintLayout`, `PrintService`, the Copies section) | The layout is covered by `PrintLayoutTests` (real size on A4 and Letter, a whole glass cut off on A4, printer margins, a selection centred, turning only when that cuts off less, fit with and without turning, never enlarged, units, printer paper, copies, the ruler page by pixel, the texts) and the copy cases of `ScanTaskTests`, `ModelsCompatTests`, `PaperSizeTests` and `IdCardTests` (same cases as macOS); the print document by `CompleteScanner.App.Tests` (written to XPS and read back: the page is the paper, each image at its place in 1/96 in, turned pages turned in their pixels, fitted pages placed smaller, copies the printer does not make repeated, every page its own picture, grey images, cancel). Checked by reading the real print system on Windows 11 without printing (the printers, the default printer's Letter paper and printable area, A4 and Letter asked of Microsoft Print to PDF, an unknown printer; the default printer and its ticket compared before and after: unchanged), by driving the view model with the demo scanner and a stand-in printer service that records the jobs (a copy from the corner at real size, the printer's paper area of the glass scanned, A4 asked and scanned, a selection centred, 3 copies on a printer that makes 2 at most, fit to page, grey, also a PDF, the feeder's stack, another printer, a printer gone, a refused job and Cancel while printing, no printer; the ID card printed on Letter at real size with the review kept, A4 on a Letter-only printer, margins reaching the card; Automatic paper following the default printer; the ruler page), with every recorded job's document written to XPS by the app's own code and its geometry read back, and by building the window without showing it: the Copy card, the Copies section and its controls, no printer, the review's Print button, rendered off screen in light and dark. **Not done:** printing to a real printer, including Microsoft Print to PDF (its file name cannot be set without its save dialog). **Unverified:** real printer margins and offsets, measured with the ruler page |
| Text output (`OcrText`, `TextExport`, `DocxWriter`, `ZipStore`, Copy Text) | Covered by `OcrTextTests`, `TextExportTests` (with `OutputFormatsTests`), `DocxWriterTests` (with `ZipStoreTests`: CRC-32 known values, exact zip bytes, the package opened with `ZipArchive`, its parts, content types and relationship checked) and the text cases of `ModelsCompatTests`, `ScanTaskTests` and `SaveActionsTests` (same cases as macOS; both platforms pin the same CRC-32 of the sample text file and Word document). Checked by driving the view model with the demo scanner, the public-domain letter scan and Windows OCR (a PDF and its text file with one OCR pass per page, no OCR when neither is asked for, a taken name kept, Scan to Word with the letter, Text and Word saved at once, Copy Text into a stand-in clipboard, a blank page, a PC without an OCR language), and by building the window without showing it: the format lists for documents and photos, Also save text, the Save Word button, the Scan to Word card, the page menu's Copy text, rendered off screen in light and dark. **Not tried:** opening the documents in Word or LibreOffice (neither is installed here), and the real clipboard |
| Share, email, open with, copy (`SaveActions`, `FileActions`, `ShareService`) | The choices are covered by `SaveActionsTests` and the after-save cases of `ModelsCompatTests` (same cases as macOS). Checked by driving the view model's real save paths with a stand-in for Windows (each after-save action after a PDF, a file saved at once and a photo batch; the Email task sharing; no share window; a refused action; a moved file; a cancelled save running nothing), by building the real clipboard data and share package without placing them anywhere, and by building the window without showing it: the bar, its buttons and menu, the narrow layout, the "After saving" choices, the Saved tab's buttons and menus, rendered off screen in light and dark. **Not tried on screen:** the share window, the Open with dialog and the clipboard themselves (checks must not send, open or overwrite anything), and Mail or Outlook as share targets |
| Troubleshooter (`Troubleshooter`, `SystemDiagnostics`, `TroubleshooterWindow`) | The checks are covered by `TroubleshooterTests` (same cases as macOS) and the Windows service and network values by `WindowsSystemStatusTests`. Checked by driving the view model with stand-in connections and a stand-in for Windows (the snapshot, the order of the checks, devices.txt, Refresh, Copy diagnostics and Settings refused, a busy scanner at connect and at scan, a connection that works clearing it, a cancelled scan not counting), by reading the real WIA service and network on Windows 11 (Running and Public, as `sc query` and `Get-NetConnectionProfile` report, from UI and thread-pool threads), by copying to the real clipboard with the user's clipboard saved and restored, by an address added by hand on loopback where nothing listens, by a discovered scanner (a stand-in service for a loopback scanner) that stays listed, selected and connected across a Refresh when Windows aborts either network watcher, and dropped only once the restarted watcher's first pass did not find it again, and by building the sidebar, error bar and troubleshooter window without showing them: the header button, the empty state's links, the error bar's Troubleshoot (and none on a file or photo error shown later), one card per check with its buttons and screen-reader names (each card a named group in the UI Automation tree), a Refresh while one runs ignored, rendered off screen in light and dark. **Not tried on screen:** opening Windows Settings and the real Add scanner dialog from it. **Unverified:** a stopped or disabled WIA service, a TWAIN install with 32-bit-only drivers, and a scanner that is really busy in another app |
| Receipts (`ReceiptDetector`, `ReceiptEnhancer`, `ReceiptDateExtractor`, the review) | Covered by `ReceiptTests` (two receipts on a white lid found apart along their paper, cut around their print when the paper is as light as the lid, a 2 × 11 in receipt that is too long for a page but not for a receipt, prices far from the items, two receipts 0.15 in apart, one receipt per feeder sheet, nothing on the glass, a 300 dpi scan, the enhancer on fading paper, little print and a dark logo, the date rules and the 99-case date set, the texts) and the receipt cases of `ScanTaskTests`, `ModelsCompatTests`, `NamingTemplateTests` and `MockScannerTests` (same cases as macOS, on the same synthetic beds checked by checksum). Checked on harder synthetic beds (four receipts on a white lid, an open lid and with invisible paper, 12° tilts, receipts in a column 0.2 in apart, a receipt lying sideways, an 11 in receipt at the glass's edge: all found and held whole; two receipts 0.15 in apart with paper as light as the lid are not told apart), by driving the view model with the demo scanner and Windows OCR (both receipts found and cut along their paper, a gray Compact PDF each with a text layer named by its own date, one PDF for all named by the earliest, JPEG files, the text beside each PDF, today's date without OCR, OCR that fails, a save cancelled while reading, Fix crop, Discard) and by building the window without showing it: the Receipts card, the inspector's Receipts section and its switches, one PDF off for JPEG, the review's title and save button, rendered off screen in light and dark. **Unverified:** real thermal receipts on a real lid (see [Receipts](#receipts)) |
| Batch of separate documents (`PatchCodeDetector`, `DocumentSplitter`, `SavePlan`, the strip's gaps) | Covered by `PatchCodeTests` (all six codes across and down the page, ±2.5° and ±3°, the separator sheet at 100 and 300 dpi and turned, its bar widths, no code on text, a ruled table, blank pages, photos), `DocumentSplitterTests` (every mode, the two-sided blank-sheet rule, separators in a row, empty documents, every N sheets with an odd last sheet and skipped sheets, splits and joins by hand and their undo, keeping a separator page, names, also across a change of the settings, the strip's texts) and `SavePlanTests` (the documents, the texts, all or nothing on success, failure and cancel), and the split cases of `ModelsCompatTests`, `ScanTaskTests`, `PageProcessorTests`, `NamingTemplateTests` and `MockScannerTests` (same cases as macOS). Checked by driving the view model with the demo scanner's batch stack and stand-ins for OCR, the file actions and the printers (the task's settings and card, three PDFs of 2, 1 and 2 pages named with their number, the separators left out, the queue and its spool files cleared; joining, splitting and undoing by hand, keeping a separator page, naming a document from any of its pages, turning and moving pages; a save whose third file cannot be written and one cancelled during the second document leaving no file and the queue intact, then saved again with the text beside each PDF; three text files; both sides with blank backs skipped and separator backs left out; at blank sheets; every 2 sheets; no split ending the task; the separator sheet printed on Letter and A4 stand-in printers (and on the printer's paper when the scan asks for Legal), read back as Patch T, and refused without a printer, then saved as a PDF without one, a page of the usual paper read back as Patch T, and saved again under the next free name; a named first page skipped and kept again with the name following it, and left out and saved again by a change of what counts as blank, of Skip blank pages and of the split, a 300-character name cut to 100; the PDFs' size, the text files beside them and "no text was found" in the status; the last PDF size put back after a failed or cancelled save; another task unchanged) and by building the window without showing it: the card, the Split into documents choice and its hint, Print separator sheet, Sheets per document, the strip's badges, gaps and bars, a click on a gap joining two documents, the save button and label, the name box's 100-character limit, Save separator sheet (PDF) and its hint, Skip blank pages greyed out with the reason at blank sheets one-sided and back with both sides, the choice greyed out when each scan is saved at once, rendered off screen in light and dark. **Not tried on screen:** the name box (a popup window) and the page menu. **Unverified:** printed separator sheets scanned by real feeders (see [Batch of separate documents](#batch-of-separate-documents)) |
| eSCL backend (`EsclScannerBackend`) | **Experimental, untested against hardware** — see [Network scanners](#network-scanners-escl) below for discovery, adding by address and HTTPS. Feeder-only devices offer no flatbed or preview; feeder jobs ask for the paper size's region, clamped to the feeder (the feeder's own sheet size for Automatic, at most 17 in tall); two-sided feeder jobs send `<scan:Duplex>true</scan:Duplex>` and use the two-sided feeder's capabilities (`AdfDuplexInputCaps`) when the device lists them, and a device that lists no two-sided feeding scans one side and says so; black & white is requested as grayscale and thresholded by the app, because most devices reject 1-bit JPEG; busy (HTTP 503) answers are retried for up to 60 s; relative job addresses are resolved; when a job fails, the scanner's status explains it (empty feeder, jam, cover open, …); a feeder job that fails partway (an error answer, a dropped or stalled connection, a page that cannot be read) keeps the pages already received and tells the user how many were kept and why it stopped; a job that is cancelled or cut short is deleted on the device. The protocol client (`EsclClient`, `EsclScannerSession`) is covered by `EsclClientTests` through a stub HTTP handler. Checked against local fake eSCL servers (plain and HTTPS), not a real device |

Known divergences from the macOS app (all documented in the source):

- `ImagePipeline` re-implements the Core Image filters as per-pixel math — visually close,
  not bit-identical; auto-enhance is a histogram auto-level rather than Apple's suggestion
  list.
- The demo scanner's document page draws text-shaped bars, not real glyphs (Core has no
  font rasterizer), so OCR demos need a real scan. Its receipts are the exception: they are
  printed in a plain stroke type drawn pixel by pixel (the same on the Mac), which Windows OCR
  reads.
- WIA, eSCL and TWAIN exist only here, so their logic in Core (`WiaErrors.cs`, `Escl/`,
  `Twain/`) and its tests (`WiaErrorsTests`, `EsclTests`, `EsclRetryTests`,
  `EsclClientTests`, `EsclDiscoveryTests`, `EsclTrustTests`, `TwainScanLoopTests`,
  `TwainRasterTests`, `TwainScanRequestsTests`) have no Swift counterparts: the Mac reaches
  the same scanners through ImageCaptureCore, whose Bonjour browsing also finds network
  scanners. The scanner problems they report (`ScannerProblem`) are shared with macOS.
- The troubleshooter's checks (`Troubleshooter`) are shared, but each app fills in what it can
  read. Windows reads the WIA service, the network category, TWAIN and the addresses added by
  hand (`WindowsSystemStatus.cs` and its `WindowsSystemStatusTests` have no Swift twin); the Mac
  reads only whether ImageCaptureCore is browsing, since macOS offers no API for its scanner
  drivers, sharing or the Local Network permission, so those are tips there. The Mac links to
  Image Capture and to Printers & Scanners instead of adding a scanner by address, which macOS
  cannot do.
- Only Windows offers a connection chooser: the Mac merges its USB, Bonjour and shared
  entries for one scanner by ranking alone (USB first) and has no preferences file to keep a
  choice in.
- The PDF text layer emits WinAnsi text; characters outside Latin-1 degrade to `?` in the
  invisible layer only.
- Filename sanitization strips the full Windows-reserved character set, not just `/` and `:`.
- WIA hot-plug is detected by polling, since WIA device events are not wired up (macOS gets
  add/remove callbacks from ICDeviceBrowser instead). The list is re-read every 10 s, backing off
  to 60 s, while no WIA scanner is listed, and every 60 s while one is, so unplugged scanners
  disappear and new ones appear. A scanner that turns out to be gone when a scan starts
  triggers an immediate re-read.
- Cancelling a multi-file export (photo batch, per-page images) also removes the files that
  batch already wrote, so the review stays open and can simply be saved again.
- Closing the window quits the app, whereas on macOS the app keeps running. So closing asks
  first while a scan or save is running, or while pages or detected photos are unsaved. A
  running operation is then cancelled and allowed to finish its cleanup before the window closes.
- Rotating a saved JPEG re-encodes it at its own estimated quality (read from the file's
  quantization table) instead of a fixed 95%.
- Email: the Mac starts a new Mail message with the files attached; Windows has no such route
  (no Simple MAPI), so Email opens the share window, where Mail and Outlook are listed. The
  actions after a save are a bar above the window on Windows and buttons in the status bar on
  the Mac.
- Two-sided scanning: the Windows connections report whether the feeder scans both sides when
  they connect; ImageCaptureCore tells only once the feeder is selected, which can take a while on
  a sleeping scanner, so the Mac asks when the feeder is first used, again until the scanner has
  answered (until then it offers both sides, and a scan asked for both sides on a feeder that
  turns out to scan one says so). Scans and previews wait for a check under way. The Mac also reorders a feeder that reads the last sheet first
  (`reverseFeederPageOrder`). The Mac inspector leaves out choices it cannot use and says why;
  Windows greys them out with the reason.
- Blank pages: the check is the same code on both platforms, but the Mac reads a page's pixels
  through CoreGraphics in bands of rows (`GrayImage(cgImage:sourceDPI:analysisDPI:)`), so a page
  that CoreGraphics decodes slightly differently from WIC can give a slightly different ink
  coverage. The demo scanner's blank backs show its own front through, which the Mac draws with
  real glyphs.
- Crop and straighten: the plan (sheet, angle, canvas) is the same code on both platforms, on the
  same gray copy; the snap of the sheet's edges at full resolution draws the region with
  CoreGraphics on the Mac and samples it with `RgbaImage` on Windows, so a crop can differ by a
  pixel or so. The swap button sits under the page in the Mac strip and on the page on Windows.
- Printing: the layout is the same code on both platforms. Windows prints straight to the chosen
  printer with no dialog; the Mac shows the standard print panel (platform convention), already
  set to the printer, the paper, the copies and 100 %, and saves the copy's PDF only once the user
  printed. The Mac's printer makes the copies itself; Windows repeats the pages for a printer that
  cannot make that many. The Windows test project for the print document has no Swift twin; the Mac
  checks its print PDF in `PrintDocumentTests.swift`.
- ID card: the detector, layout and page are the same code on both platforms; the side is cut out
  with `RgbaImage` on Windows and with CoreGraphics on the Mac, so a side can differ by a pixel or
  so. The review is an overlay on Windows and a sheet on the Mac. Closing the window with an
  unsaved card asks first on Windows; on the Mac the app keeps running and the card stays until it
  is saved or discarded.
- Text output: the reading order, paragraphs, text file and Word document are the same code on
  both platforms (the same bytes for the same lines), but the lines come from different
  recognizers (Windows OCR here, Vision on the Mac), so the same scan gives different text. Copy
  Text puts "\r\n" line breaks on the Windows clipboard and "\n" on the Mac pasteboard. The Mac's
  PDF writer asks for each page's text layer while it draws the page (`PDFTextLayer`); Windows
  reads the pages first and hands the writer their lines.
- Receipts: finding, cleaning up and dating are the same code on both platforms, on the same gray
  copy, so the same scan gives the same regions and pixels; the dates come from different
  recognizers (Windows OCR here, Vision on the Mac), so a receipt can be dated differently. The
  day-or-month preference is the culture's short date pattern here and the Mac formatter's pattern
  for day, month and year there.
- PDF sizes: Windows writes the planned JPEG into its own PDF writer. The Mac, whose PDFs come
  from CoreGraphics, encodes the same plan with ImageIO and draws a JPEG-backed image, which
  CoreGraphics is expected to store unchanged; this, and the resulting file sizes, still need
  checking on a Mac (the Swift tests check the plan, the JPEGs and the size order).

## TWAIN

TWAIN reaches scanners whose makers ship only a TWAIN driver (many document scanners) or
whose TWAIN driver offers more than their WIA one. It is Windows only; the Mac reaches the
same scanners through ImageCaptureCore.

- **What it needs.** The TWAIN Data Source Manager (`C:\Windows\System32\TWAINDSM.dll`) that
  scanner drivers install. The app never ships it (it is LGPL). Without it the TWAIN backend
  lists nothing, and `%LOCALAPPDATA%\CompleteScanner\Logs\devices.txt` says
  "TWAIN: not installed"; the troubleshooter says so too and explains what installs it. The
  drivers are listed once, at start: a driver installed while TWAIN works appears after a
  restart (while TWAIN is missing or would not start, the troubleshooter's **Refresh** lists
  again). A listing that fails (the Data Source Manager would
  not open, or a driver held it up past 60 s) is tried again after 30 s, 1, 2 and then every
  5 minutes, and a listing that finishes late is still used.
- **64-bit only.** The app can load only 64-bit drivers (`C:\Windows\twain_64`). Drivers
  installed only for 32-bit programs (`C:\Windows\twain_32`) are listed in `devices.txt` as
  "32-bit only" and cannot be used yet; the troubleshooter names them and suggests the maker's
  64-bit driver.
- **Installed, not connected.** TWAIN lists installed drivers, so a scanner that is off still
  has a row (captioned "TWAIN driver" when no other connection reaches it). Connecting then
  says the scanner is offline. The app therefore never picks such a row on its own (at start,
  when a scanner appears while the demo scanner is selected, or when the WIA or eSCL
  connection in use goes away and only TWAIN still lists the scanner, which then counts as
  gone); it connects only when the user chooses it.
- **Its own thread.** Every TWAIN call runs on one dedicated thread; NTwain runs the driver's
  messages and the transfers on its own message-loop thread. A driver that hangs while
  scanning without its own window never blocks the app: opening a scanner, reading what it
  offers and closing it give up after 60 s, and getting a scan going (an earlier scan
  finishing its stop, negotiating and, without the driver's window, enabling the source,
  where a driver may show a message box) after 90 s ("not responding"); further TWAIN calls
  are then refused at once until the stuck one returns. A scan gives up when the scanner says nothing for 3 minutes, except
  during a native transfer, which is one call lasting the whole physical scan (only Cancel
  ends that wait). **Cancel** returns at once; the pending transfers are then reset
  (`MSG_RESET`) and the source is disabled in the background.
- **Transfers.** Pages arrive as memory strips (1-bit black & white, 8-bit gray, 24-bit
  color) that the app assembles; when a source does not offer memory transfers, or sends a
  format the app cannot read, the session switches to native (bitmap) transfers. Black & white
  is scanned as 1-bit by the scanner, unlike eSCL.
- **Feeder.** A feeder batch scans until the feeder is empty. An empty feeder before the
  first sheet says "Load paper in the feeder"; a jam or double feed later keeps the sheets
  already scanned and says why. Two-sided scanning (`CAP_DUPLEXENABLED`) is switched on only
  when both sides are asked for and the source reports a two-sided feeder (`CAP_DUPLEX`), so a
  driver that defaults to it otherwise still scans one side. The pages are arranged as fronts
  and backs only when the source confirms it scanned both sides: `CAP_DUPLEXENABLED` read back
  after it is set, or, with the scanner's own window, after the scan (the user may have turned it
  off there); when it cannot be confirmed the pages are kept one-sided. A feeder paper size is asked for
  as the source's own size (`ICAP_SUPPORTEDSIZES`) when it lists it, otherwise as the frame.
- **The scanner's own settings window.** For TWAIN connections the Scanner section of the
  inspector has **Use the scanner's own settings window**: Scan then opens the driver's
  window, where resolution, color, area and source are chosen and the scan is started; the
  app accepts as many pages as the window sends. The choice is kept per connection in
  `preferences.json` (`twainDriverWindow`). A driver that cannot scan without its window
  always uses it, and then offers no preview. The window is opened without an owner, so it
  cannot disable the app's window (Cancel stays usable) or tie the app's input to a driver
  that hangs; it may therefore open behind the app's window, and a driver that picks the
  foreground window as its parent on its own can still do both. While the window is open the
  scan waits without a time limit; Cancel ends it.
- **To check on real hardware:** driver names and grouping (`devices.txt`), memory transfers,
  feeder and empty-feeder behaviour, cancel during a long transfer, drivers that show their
  own message boxes while opening or enabling, the driver window (and whether it opens in
  front without an owner), native transfers of large scans, and the TWAIN Working Group's sample
  data source (installing it needs administrator rights).

## Network scanners (eSCL)

Driverless network scanners (eSCL, also called AirScan or Mopria Scan) are reached over
HTTP or HTTPS. Windows 11 often installs the same scanner as a WIA device too; both
connections are then one row (matched by the scanner's eSCL UUID or model name), and the
row's **via** menu chooses between them.

- **Found automatically.** The app browses DNS-SD for `_uscan._tcp` and `_uscans._tcp`
  services through Windows' own mDNS stack (a `DeviceWatcher` over association-endpoint
  services), so nothing listens on port 5353 itself and no firewall prompt appears. A
  scanner advertising both services is one entry; its name is the model from the TXT record
  (`ty`), its hardware id the TXT `UUID`. Addresses are tried HTTPS first, then HTTP; within
  each, IPv4, then the `.local` host name, then IPv6 (link-local only with an interface zone).
  A connection that fails, including a failed TLS handshake, moves on to the next address.
- **Add scanner by address.** The **+** button next to **Scanners** (and the link in the
  empty list and in the troubleshooter) opens a dialog that takes an IP address, a host name, `host:port` or an
  `http(s)://` URL. It checks that an eSCL scanner answers there before adding it, and
  explains what is wrong when nothing does. Addresses are kept in
  `%APPDATA%\CompleteScanner\escl-hosts.json` (a JSON list of strings, the file earlier
  versions asked to edit by hand; hand-written entries keep working). They are checked at
  start, and ones that do not answer are tried again every minute. A row reached through an
  added address has **Remove address …** in its context menu; a scanner that is also found
  automatically stays listed.
- **HTTPS and certificates.** Scanners make their own certificates, which Windows cannot
  check. The first time the app connects to a scanner over HTTPS, its certificate is trusted
  and pinned (trust on first use): the SHA-256 of its public key is kept, with the scanner's
  UUID and the addresses it was seen at, in `%APPDATA%\CompleteScanner\escl-trust.json`. Only
  the **Add scanner by address** dialog shows a new certificate's fingerprint and asks first.
  A new certificate is pinned only once the scanner has reported its UUID: one that comes
  with the UUID of a scanner trusted with another certificate counts as a changed
  certificate, wherever it was reached. If the file cannot be saved, the certificates trusted
  meanwhile stay trusted until the app closes.
  If a scanner later presents a different certificate, the app does not connect and warns
  that it changed (a firmware update or reset can do that, but so can another device posing
  as the scanner). It asks whether to trust the new certificate only when the user chooses
  that scanner (the default answer is Cancel; trusting replaces the pin). When the app picked
  the scanner on its own, it shows the warning without asking, does not pick that scanner on
  its own again until the app restarts, and moves on to another one. A refused certificate
  never falls back to plain HTTP. A certificate Windows itself accepts (valid chain and name)
  is used without asking.
- **To check on real hardware:** discovery of real scanners (the names, TXT records and
  addresses they advertise appear in `devices.txt`), HTTPS with real scanner certificates
  and TLS versions, link-local IPv6 connections, and how long Windows keeps listing a
  scanner that was switched off (a service unregistered on this PC was still reported 30 s
  later; connecting to such a scanner fails with the usual message).

## Settings files

Presets, scan settings and app preferences are JSON files in `%APPDATA%\CompleteScanner\`
(`presets.json`, `settings.json`, `preferences.json`; the preferences hold the appearance,
the connection chosen per scanner and the TWAIN connections that use their driver's
window), next to the network scanners added by address (`escl-hosts.json`) and their
trusted certificates (`escl-trust.json`). The scan settings and presets remember the task
they were set up for as text (`"taskId": "document"`), left out when there is none, so a task
added by a newer version is kept by an older one. They also hold an `"output"` object with the
PDF size and the after-save action (`"output": {"pdfSize": "standard", "afterSave": "none"}`); a
file without them, or with a value this version does not know, reads as Standard and Do nothing.
Two-sided scanning and the paper size are top-level keys (`"duplex": "off"`, `"backBinding":
"longEdge"`, `"paperSize": "auto"`); a file without them, or with a value this version does not
know, scans one side on the whole area. Blank pages are in a `"document"` object
(`"document": {"removeBlankPages": false, "blankSensitivity": "medium", "autoCrop": false,
"autoStraighten": false}`); a file without it keeps every page and leaves pages as scanned, and a
sensitivity this version does not know reads as Medium. How the user wants a task done is in a
`"taskOptions"` object (`"taskOptions": {"idCardPaper": "auto", "idCardSaveSidesAsImages": false}`),
kept when a task is picked; a file without it, or with a paper this version does not know, reads as
Automatic without side images. A first run starts without presets: the task
cards replaced the five starter presets earlier versions wrote, and presets files that already
hold them keep them. They load across versions the same way as on macOS (`../CONTRACTS.md`, rule 6): a value this version does not understand resets only
that setting; a file that cannot be decoded is kept next to it as
`<name>.unreadable-<yyyyMMdd-HHmmss>.json` before defaults are written; and a file that cannot
be read at all (for example, locked by another program) is left alone and not overwritten
until the app restarts.

## Porting workflow

When an algorithm changes on either side:

1. Change the implementation and its test in that platform's suite.
2. Port both to the other platform (the sources carry matching structure and comments —
   `PhotoDetector.cs` is diffable against `PhotoDetector.swift` stage by stage).
3. Both `swift test` (repo root) and `dotnet test` (this directory) must pass.
