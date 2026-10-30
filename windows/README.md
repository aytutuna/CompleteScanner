# Lazy Scan for Windows

The Windows sibling of the macOS Lazy Scan app, following the **shared core, native
UI per platform** architecture:

- **`LazyScan.Core`** — a platform-neutral .NET 10 class library with **zero
  dependencies**: photo detection (thresholding → morphology → connected components →
  convex hull → rotating calipers), the image adjustment pipeline, naming templates,
  presets/settings persistence, a dependency-free searchable-PDF writer (`PdfBuilder.cs` over
  `PdfObjectWriter.cs`, with a Unicode text layer in an embedded font built from code,
  `GlyphlessFont.cs`, PDF/A-2b output, `PdfA.cs`, and AES-256 password protection,
  `PdfEncryption.cs`, with `System.Security.Cryptography` only; all of it has a Swift twin that
  writes the same bytes, through which the Mac writes every PDF; and a reader of existing PDFs,
  `PdfReaderLite.cs` over `PdfSyntax.cs`, that `PdfAppender.cs` uses to add pages to them as an
  incremental update), the scanner
  backend contract, scanner problems with their user-facing text (`Troubleshooting.cs`), the
  "Why isn't my scanner listed?" checks (`Troubleshooter.cs`), and the hardware-free demo
  scanner. It is a type-for-type port of the
  Swift `LazyScanKit` core, the Swift package's shared target, which builds for macOS and
  iOS (the Mac's views and system services are in `LazyScanMac`, the iPhone's in
  `LazyScanIOS`, with the iPhone app's Xcode project in `../ios/`; see `../CONTRACTS.md` for
  the shared conventions, especially the four
  coordinate systems). It also holds the testable protocol logic of the
  Windows-only backends, which has no Swift twin because macOS reaches the same scanners
  through ImageCaptureCore: the WIA error and document-handling tables (`WiaErrors.cs`), the
  decisions of the Windows Scan backup connection (`WindowsScan.cs`: capabilities, the scan
  request, error mapping and its diagnostics; see [Windows Scan](#windows-scan-backup-connection)),
  and the TWAIN scan logic (`Twain/`: the acquisition state machine behind an
  `ITwainTransport` interface, memory-strip and bitmap conversion, the paper-size table and
  the condition-code mapping, and the protocol of the 32-bit TWAIN helper: its messages and
  their encoding, `TwainHelperProtocol.cs`, the helper's end, `TwainHelperServer.cs`, and the
  app's end with a transport that forwards each TWAIN call to it, `TwainHelperClient.cs`), and the Windows service and network-category values the
  troubleshooter reads (`WindowsSystemStatus.cs`). The eSCL protocol and connection (`Escl/`:
  capabilities parser, job request builder, status mapping, 503 retry policy, DNS-SD TXT
  records, address parsing, endpoints, the added-address list, certificate pinning for HTTPS,
  and the HTTP client and session, `EsclClient.cs` and `EsclScannerSession.cs`) have Swift
  twins in `Sources/LazyScanKit/Escl/`, for the iPhone, which has no ImageCaptureCore
  scanners; see [Network scanners](#network-scanners-escl). Device merging (`DeviceMerge.cs`: one row per physical
  scanner, whichever backends list it) is shared with macOS. So is the page clean-up stage
  (`PageProcessor.cs`: the steps every scanned page goes through before it is queued) and the
  image toolkit it works with (`GrayImage.cs`, `BackgroundMap.cs`, `MaskOps.cs` next to
  `RgbaImage.cs`), starting with blank-page detection (`BlankPageDetector.cs`), crop and
  straighten (`DocumentGeometry.cs`) and rotating pages upright (`Orientation.cs`: which way up a
  page reads; the reading itself is the platform's OCR), the ID card task (`IdCard.cs`: finding the card on the
  glass, laying both sides out at real size and drawing the page), copy and print
  (`PrintLayout.cs`: where a page goes on a printer's paper at real size or fitted, copies, the
  ruler test page), text output (`OcrText.cs`: OCR lines in reading order and paragraphs;
  `TextExport.cs`, `DocxWriter.cs` and `ZipStore.cs`: the text file, the Word document (with its page pictures) and its
  zip package, written by hand so both platforms write the same bytes), receipts
  (`ReceiptProcessing.cs`: finding several receipts on the glass, cleaning up faded thermal
  print, and reading the receipt's date from its text for the `{docdate}` file name), splitting a
  stack into documents (`DocumentSplitter.cs`; `PatchCode.cs`: separator sheets with patch codes,
  read and drawn for printing; `Barcodes.cs`: barcode and QR separator sheets, the name a code gives
  a document, the QR sheet drawn for printing and Code 39 for the demo, with the reading itself left
  to the app; `SavePlan.cs`: several files saved all or nothing), and books and
  magazines (`BookSplitter.cs`: the gutter of an open book found on a spread, which is cut into
  its pages in reading order; `SpineShadow.cs`: the shadow along the spine softened on each page),
  and photos of documents (`PhotoDocumentDetector.cs`: a page's four corners found in a camera
  photo; `PerspectiveCorrector.cs` over `Quad.cs` and `Homography.cs`: the page made upright with
  its perspective corrected; `CaptureStability.cs`: when a held-still page should be taken, and
  `FrameQuality.cs`: whether its frame is sharp and lit enough; `DocumentEnhancer.cs`: a camera page's
  lighting evened out, the paper white and the print black;
  `PhotoImport.cs`: importing photos of documents as pages; the camera geometry shared with the
  iPhone app: `PerspectiveWarp.cs`, the reference warp of camera pages, `CaptureScale.cs`, a
  captured page's real size and what the camera recorded about it, `MultiQuadPicker.cs`, the
  objects picked from one shot, `CaptureObjects.cs`, those objects as pages (with `PhotoReview`, the
  photo review's title and Save button), and `GlareDetector.cs`, glare on a card or a glossy print),
  and the phone companion (`Companion/`:
  the certificate pin `SpkiFingerprint.cs`, the pairing code `PairingUri.cs`, the one-time pairing
  window `PairingSession.cs`, the paired phones `PairedDeviceStore.cs`, the HTTP subset
  `CompanionHttp.cs` and the messages `CompanionProtocol.cs`, shared with the Swift package; and,
  Windows only until the Mac's server, the TLS server and its requests `CompanionServer.cs`,
  `CompanionRouter.cs`, the inbox and outbox, rate limits, the trusted-network rule
  `CompanionNetworks.cs`, the firewall verdict and the phone checks, and `CompanionHost.cs` /
  `CompanionService.cs`, which listen only on trusted networks; see
  [Send from your phone](#send-from-your-phone)).
- **`LazyScan.Core.Tests`** — the conformance suite: the macOS test cases ported to
  xUnit with the same fixtures, geometry, and tolerances. **This is the contract that keeps
  the Swift and C# cores behaviorally identical** — change an algorithm on one side, port
  the change, and both suites must stay green. Its one package beyond the test framework is
  [PdfPig](https://github.com/UglyToad/PdfPig) 0.1.16 (Apache-2.0), pinned to that exact
  version and used by the tests only: it opens the PDFs the writer makes to check their pages,
  text layer and metadata. Neither Core nor the app references it.
- **`LazyScan.App.Tests`** — checks of the app's own Windows code that need WPF but no
  window and no device: the print document is written to an XPS file and read back (paper size,
  where each image lands, copies, grey, cancel), barcodes and QR codes are read with ZXing.Net
  on synthetic scans, the 32-bit TWAIN helper is started for real and scans its stand-in
  scanners (`TwainHelperTests`), the Windows Scan device watcher runs in the unpackaged test
  process (`WinRtScannerTests`), and photo files are read with WIC as an import reads them (the
  orientation tag, a HEIC photo Windows cannot decode, the file only read; `PhotoFileReaderTests`),
  and a phone's document becomes queue pages, the network list and firewall rules are read (read
  only), and the phone link's certificate is kept in a certificate store of the test's own
  (`CompanionAppTests`; the certificate case runs only with `LAZYSCAN_CERT_STORE_TESTS=1`,
  which CI sets).
  Nothing is sent to a printer.
- **`LazyScan.TwainHelper`** — the 32-bit TWAIN helper (x86, .NET 10): a small console
  program without a window that the app starts when a scanner driver is installed only for
  32-bit programs (see [TWAIN](#twain)). The app's build copies it next to `LazyScan.exe`.
- **`LazyScan.App`** — the native Windows shell (WPF, .NET 10): main window with
  sidebar/inspector/preview-canvas/page-strip/photo-review, a view-model porting the shared Swift
  `AppState` orchestration, and Windows service implementations (WIA, Windows Scan, eSCL and TWAIN
  scanning, Windows.Media.Ocr, WPF imaging codecs). Its package dependencies, each pinned to an
  exact version, are [NTwain](https://github.com/soukoku/ntwain) 3.7.6 (MIT) for TWAIN,
  [ZXing.Net](https://github.com/micjahn/ZXing.Net) 0.16.11 (Apache-2.0) for barcode and QR
  separator sheets, and [ONNX Runtime](https://github.com/microsoft/onnxruntime) 1.24.2 (MIT)
  for the page corner model (see [Third-party notices](#third-party-notices)).

The macOS app is unchanged and remains the reference implementation.

## Build & run (Windows 10 19041+ / Windows 11)

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0), or Visual
Studio 2026 (18.0+), the first Visual Studio release that supports .NET 10. The 32-bit TWAIN
helper also needs the 32-bit (x86) .NET 10 Desktop Runtime to run; without it the app works as
before, the helper reports that it cannot start, and its tests are skipped (CI installs it and
requires them, `LAZYSCAN_REQUIRE_TWAIN_HELPER=1`).

```powershell
cd windows
dotnet test                                  # the conformance suite and the app's print-document checks
dotnet run --project LazyScan.App     # launch the app
```

The main window has four tabs, like the macOS app:

- **Start** — "What are you scanning?": the user's presets first (only when there are some), then
  one tile per task in three groups (`TaskCatalog.Sections`): **Documents** (Document to PDF, Stack
  from feeder, Two-sided document, Separate documents, Scan to Word, Email a document, Archive
  document), **Photos & images** (Photos, Restore old photos, Quick scan) and **Other** (ID card,
  Photocopy, Receipts, Book or magazine). A tile is an icon and a title; what the task does (its
  one-line subtitle) and what it sets are its tooltip (also on keyboard focus) and its help text for
  screen readers. Picking a tile sets everything up for that task, keeps the save folder, fits
  the settings to the connected scanner and opens **Scan**; a tile the scanner cannot do (the
  feeder task on a flatbed-only scanner, Photocopy without a printer) is greyed out with a short
  reason ("Needs a document feeder", "Needs a printer"). On **Scan** a banner
  names the active task and says what to do in one line, with the fuller guidance behind its ⓘ
  (`TaskStep.Prompt` and `Help`, worded for the settings by `TaskCatalog.ShownStep`: with the
  feeder as the source Document to PDF asks to load the pages and its button reads **Scan stack**,
  and with **Collect pages before saving** off it says each scan is saved right away);
  **Change task** goes back to Start and the close button leaves the task (its settings stay).
  The task is saved with the settings, so a restart comes back to it. A first run opens on Start,
  later runs on Scan. The task tiles are one Tab stop, the presets another; the arrow keys move
  between tiles and Enter or Space picks one.
- **Scan** — preview canvas, page queue and the settings inspector (Preview/Scan stay pinned
  at the bottom). Adjustment sliders are centered (-100…+100, 0 = neutral) and preview live
  on the canvas; queued pages can be reordered, rotated 90° or removed; detected photos open
  in a review where each crop can be corrected by hand. **Cancel** works in every busy phase
  (scanning, processing, photo detection, OCR, PDF writing, exports) and never leaves a
  partial file behind.
- **Scans** — this session's scans, newest first; click one to enlarge it. A card shows the
  scan's mode as an icon and the time; resolution, pixel size and how long ago are its tooltip.
- **Saved** — the destination folder's files, newest first, with open, share, show-in-Explorer
  and rotate-in-place for JPEG/PNG/TIFF on each card; its **…** button and its context menu
  (right-click, Shift+F10 or the Menu key) add open with, email and copy (see
  [Share, email, open with, copy](#share-email-open-with-copy)).

### Less text on screen

Each screen shows icons, short labels and what prevents a mistake; explanations are one hover or
one click away. Both halves of the text spec are built: the Windows layout, and the shared Core
strings, shortened in C# and Swift together (task titles and subtitles, a step's short prompt and
its help, the troubleshooter's one-line details with their more help, the error bar's title by
problem, a few words of help per choice, the page strip's labels and badges, the photo import's
texts); the Mac mirrors the layout (see the main README).

- **Inspector sections.** Scanner (Source, Sides, Flip on, Paper size, Resolution, Color), Output
  (Format, PDF size, the last PDF's size, Searchable PDF, Collect pages before saving, Save to; in
  Photos mode it is **Photos**: Find each photo, Straighten photos, Format, Save to), Adjustments,
  Pages (Skip blank pages, Crop to page, Straighten pages, Rotate pages upright, Split facing
  pages), Split into documents, Archive & password (PDF/A and the password) and More options (Also
  save text, After saving, File name), after the Photocopy or Receipts section of those tasks. The
  task section, Scanner and Output start open, the rest collapsed; each stays as the user leaves
  it (`inspectorSections` in `preferences.json`, not in presets), and the Restore old photos, Book
  or magazine, Separate documents and Archive tasks open their own section (`InspectorSections` in
  Core, which also decides which sections a setting shows, their titles, summaries, dots and accessible
  names: `Shown`, `Title`, `Summary`, `Changed`, `AccessibleName`, `WritesPdf`, `TextApplies`, the rules
  the iPhone's Settings screen is built on). A collapsed header shows what is on
  in it ("Skip blank · Upright +1", "Separator sheets", a lock and "Password on") with an accent
  dot when anything differs from the defaults; its accessible name carries the same summary.
- **Hide or disable.** What does nothing for the task or format is hidden (Pages and Split for
  copies and receipts, Archive & password and Searchable PDF when the save writes no PDF: a queue
  of JPEG pages still saves a PDF, so they show for it, and Archive & password shows for a copy
  with Also save as PDF on). **What counts as blank** shows whenever collected pages are checked
  for blanks, Skip blank on or off (it decides which pages the strip flags and which sheets are
  separators), with "Check flagged pages before saving" at High. What conflicts with another choice is greyed out with a short reason and a glyph next
  to it ("Needs the feeder", "Not with PDF/A", "Not with a password", "Not with two-sided", "Needs
  Collect pages", "Needs {docdate} in File name"); the full sentence is its tooltip (shown on disabled controls too) and its help
  text. The captions that explained a switch are its tooltip and help text now.
- **ⓘ flyouts** (`InfoButton`, a Popup styled as a Fluent flyout) hold procedures and keyboard
  help: the task banner's fuller guidance (`TaskStep.Help`; the banner shows the step's one-line
  prompt), how splitting works (`SplitMode` steps), where a network scanner's address is, and the
  keys of the crop, spread and corner editors (`PhotoImport.EditorKeys`). The flyout takes focus,
  closes with Esc and gives the focus back.
- **State instead of instructions.** "Drag to select an area" on a preview until an area is
  selected, "Using the selected area" (with × to clear it) under Paper size, "Drop to add as pages"
  while photo files are dragged over the window, a **Not split** badge with **Split…** on a spread
  kept whole, a scissors or link on the gap between two pages (Split here / Join), the next file's
  name under File name (with an **Insert** menu for its parts; the parts, putting one in at the caret
  and the next file's name are `NamingTokens` in Core, shared with the iPhone's file name editor, which
  also says what is wrong with a template: "Needs a file name", "Unknown part {foo}"), "1 · front" and "1 · left" side
  badges (named "Sheet 1, front" and "Spread 1, left page" for screen readers), and the strip's
  "6 pages · 1 blank skipped".
- **Save** is a split button: **Save PDF** with a badge of the pages it saves and a lock while the
  PDF gets a password (named "Save password-protected PDF, 5 pages" for screen readers), and a ▾
  menu with **Add to existing PDF…**. Importing photos of documents is an icon button next to it.
- **The status bar** shows at most six words, facts only (`StatusLine` in Core: "6 pages added · 1
  blank", "Saved"; nothing while a review shows its own title); a
  setting changed for the scanner, or a two-sided scan that came back one-sided, stays on it as a
  short warning ("Ready — Office Scanner · feeder used", "300 dpi used", "3 pages added · one side
  only", "Saved · 600 dpi used"); its accessible name is the whole sentence, read out as it changes. The Saved bar counts
  what was saved: "3 photos · Scans", "3 receipts · Scans", "3 files · Scans".
- **The error bar** is titled by the scanner's problem ("Paper jam", "Scanner offline"; "Something
  went wrong" for any other error) and says what to do in a line (`ScannerProblems.Notice`); the
  whole message is its tooltip and help text.
- **While a review is open** (photos, receipts, the ID card), the task banner is hidden under it,
  keeping its place, and the empty stage's title and line are hidden while a banner shows (the
  import link stays).
- **Dialogs** are trimmed the same way: the troubleshooter's headline is one line ("No scanner found
  · 1 warning", `Troubleshooter.Overview`), and each check shows its one-line detail with its buttons
  and a **More help** expander for the rest (`TroubleshootCheck.More`; a passed check is one line,
  its detail the tooltip, unless it offers an action such as **Add by address…**, which keeps its
  card and button),
  the password dialog keeps its warning and a strength bar, and the add-scanner, crop, spread,
  corner and save-preset dialogs keep one line each.

The short texts both apps show are in Core with Swift twins (`StatusLine`, `InspectorSections`, `NamingTokens`,
and the reasons with the types they belong to: `DocumentSides.NeedsFeederReason`,
`BookPages.NotWithTwoSidedReason`, `BlankSensitivities.HighWarning`, `PaperSizes.SelectedAreaNote`,
`SplitMode` captions and steps, `BarcodeSeparators.StartsDocumentCaption`, `IdCardSteps.PrivacyNote`,
`PhotoImport.DropOverlay`), checked by `StatusLineTests`, `InspectorSectionsTests`, `NamingTokensTests` and the tests of
those types on both platforms. The Windows-only short texts are in `LessText.cs` (`ShortText`),
checked by `LessTextTests` in `LazyScan.App.Tests`; the PDF/A and password texts live in
`PdfA.cs` and `PdfEncryption.cs`, whose Swift twins the Mac shows. Renaming the four tasks changed no
settings file: presets and settings store the task's raw value (`taskId`: "feeder",
"photoRestore", "copy", "batch"), never its title (`ModelsCompatTests`).

A scanner that several backends reach (WIA and TWAIN for one USB scanner, WIA and eSCL for
one network MFP) is one row in the sidebar. The app connects through WIA when it can, then
eSCL, then TWAIN, and through Windows Scan only when it is chosen or the only connection left
(see [Windows Scan](#windows-scan-backup-connection)); the row's **via WIA ▾** menu chooses another connection for that scanner
(or **Automatic** again). The same menu is the row's context menu (right-click, Shift+F10 or
the Menu key), which is also the way to reach it in the folded sidebar rail; Tab moves from
the selected row to its **via** button. While a scan runs or the photo review is open, a new
choice for the selected scanner takes effect when that ends. The choice is remembered while
the scanner is reached the same ways: it is saved under the network connection's eSCL UUID
when that connection is listed and under the model name otherwise, so a choice made while the
eSCL host answered does not apply while it is offline, and the other way round. Choices for
scanners no longer present stay in `preferences.json`. The names the drivers report, and how
they were matched, are written to `%LOCALAPPDATA%\Lazy Scan\Logs\devices.txt`, so
missing aliases can be spotted on real hardware.

Pick **Demo Scanner** in the sidebar to exercise everything without hardware: scan in
Photos mode to see detection/deskew/review, or Document mode to build a PDF. Its
**Document feeder** source holds three numbered two-sided letter-size sheets (Preview is
for the flatbed, so it is off while the feeder is selected). It scans both sides in one pass,
or, with **Both sides, turned by hand**, the side facing up: it turns its stack over after the
fronts, as the user would, so the next scan delivers the backs, last sheet first. A paper size
makes it deliver sheets of that size. For the **Separate documents** task its feeder holds
seven sheets instead, the third and fifth being separator sheets (the Patch T sheet the app prints,
with a blank back; split at barcode or QR sheets, a Code 39 sheet saying "LS-SEP INVOICE 1002"
and "LS-SEP INVOICE 1003" instead, naming the document after it), so the stack splits into documents of two,
one and two sheets.

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
with its sheet and side ("2 · back").

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
  side ("Page 3, Sheet 2, back").
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
and offers **Skip**. With **Skip blank pages** on (the inspector's **Pages** section) it is dimmed and badged **Blank, skipped** instead, and offers
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
page that lies at a slant straight (the inspector's **Pages** section, under the blank-page
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

### Photos of documents

No scanner at hand: a phone photo of a page becomes a page of the queue. **Import photos of
documents…** (the button under **Preview** and **Scan**, and a link on the empty stage) picks one
or more JPEG, PNG, HEIC, TIFF, BMP or WebP files; photos dragged from Explorer onto the window are
taken too, as a copy (other files dragged over the window get the no-drop pointer; photos dropped in
Photos mode are answered with why they are not imported). Each page of a TIFF of several pages (a
fax, a scan) becomes a page; a photo of more than 150 megapixels is turned down from its header,
before its pixels are decoded, and the other photos go on. It is offered wherever the queue
collects pages (Document mode and the document tasks, also with **Collect pages** off, where the
pages then wait in the queue); not in Photos mode or the ID card, copy and receipt tasks, nor while
a stack is turned over by hand.

Each photo is read once into memory and never changed, moved or locked: the spool gets the page and
the photo as the app made them, never the file itself. The photo is turned upright by its
orientation tag (EXIF 274: all eight values, mirrored ones included), the page's corners are found
(DocAligner's FastViT-T8 on ONNX Runtime's CPU, `Services/OnnxCornerModel.cs`, as on the Mac and the
iPhone; `PhotoDocumentDetector` when the model was not fetched or finds no page) and the page is cut
out along them with its perspective corrected (`PerspectiveCorrector`). When the page is not found
clearly (confidence under 0.7, cut off by the
photo's edge, two pages, or nothing found) the **corner editor** opens with the best guess and says
why: drag each corner onto a corner of the page (a magnifier shows the photo around the corner
being moved; keys 1 to 4 select a corner, the arrow keys move it, Shift takes bigger steps); a
corner stays on the photo and the outline stays a page that can be cut out. **Use corners**,
**Use whole photo** or **Skip photo** (Esc). Every page then goes through the clean-up stage
like a scan, except crop and straighten (blank-page check, separator sheets, barcodes when the stack
is split at them, turning upright, the adjustments and color mode), and is added to the queue at
once, so **Cancel** keeps the pages already added. Its resolution is the one its shape gives when it
matches a paper size (A4, Letter, Legal, ID-1 within 3 %: the page then saves at that size), else
200 dpi. The strip labels the page **Photo**, and its swap button shows it **as photographed** (the
whole photo, saved that way at the page's resolution) and back. Photos that cannot be read are
listed in one message at the end; the others are imported. A HEIC photo needs Microsoft's free
**HEIF Image Extensions** (and **HEVC Video Extensions** for most iPhone photos) from the Microsoft
Store; without them the message says so.

Checked here on composited 12 MP phone photos of public-domain documents (the photo-detection
evaluation's renderer: a letter on wood, the same photo stored sideways with orientation 6 and as a
HEIC written by Windows' own encoder, a letter on fabric the detector is unsure of, a menu on a
white table, an empty table, a damaged JPEG, a fake HEIC and a text file), through the view model:
the letter was cut out at Letter size (219 dpi) with every corner within 0.02 % of the photo's
diagonal, identically from the sideways photo; the unsure letter, the menu and the empty table went
to the corner editor; the PDF's pages came out at Letter size, and the page shown as photographed at
the photo's size at the page's resolution; the photo files stayed byte for byte as they were. Each
photo takes about 1 s to read and search at 12 MP. Not yet: moving the corners of a page already in
the queue (remove it and import the photo again), and color profiles (a Display P3 photo is read as
sRGB).
**To check on real hardware:** real phone photos (HEIC from an iPhone, whose turn WIC may report
differently from a JPEG's; 48–50 MP photos), drags from the Photos app and from a phone's folder,
and the corner editor with a touch screen or pen.

**Camera pages (shared with the iPhone app, no Windows screen yet).** Core also holds the camera
geometry the iPhone's camera uses (I6), with the same tests as the Swift package: `PerspectiveWarp`
cuts a page out of a photo at a given size, averaging the photo down in whole blocks first when the
page is made more than twice smaller, then sampling it as `PerspectiveCorrector` does, so both
platforms give the same bytes (pinned in `PerspectiveWarpTests`); `CaptureScale` gives a captured
page its real size by its shape (A4, Letter, Legal, ID-1; receipts 80 or 57 mm wide; 4 × 6, 5 × 7
and 3.5 × 5 in photos, a 10 × 15 cm print having 4 × 6 in's shape and so reported as 4 × 6 in; within
3 %), never upsampling and at most 600 dpi, else 200 dpi with the size marked as made up;
`MultiQuadPicker` picks receipts, photos, a card or a page out of the outlines found in one shot (an
outline holding one smaller fitting outline is one object, such as a print and its picture; one
holding several separate ones that cover at least 15 % of it, such as an album page or a sheet
under receipts, is the background, while small features such as windows in a print's picture leave
the print whole). A page that carries what the camera recorded (`ScannedPage.Capture`)
is cut out by `PerspectiveStep` (`PageProcessor.ForCapture`), and crop and straighten leave it alone.
The facts follow the photo: `CaptureFacts.Oriented` turns and mirrors them with it (as
`PhotoImport.Oriented` turns its pixels) and `ScaledTo` resizes them; `PerspectiveStep` scales the
facts to a photo kept at another size and records them in that photo's pixels, so the corners always
match the photo kept as the other version, and leaves a photo turned without its facts as it is
(`DescribesPhoto`). Pages a phone sends keep those facts (companion packages carry them from format
1.1). The iPhone app uses this to import photos and to bring in Apple's document scanner's pages (I7),
and for the photos of its own camera (I8), which go through the same import: the page outline it
draws live over the preview is found by the same `PhotoDocumentDetector` on small frames, and how
steady it is by the same `CaptureStability`, so the camera itself (AVFoundation, iOS only) adds
nothing to Core; the page finder without Vision (`QuadFinder`) and an import that uses these on
Windows are later (I17).

**The camera's automatic shutter and clean-up (I9, shared with the iPhone app, no Windows screen
yet).** `FrameQuality` measures a live frame over the page found in it: how sharp (the variance of the
luma's Laplacian) and how bright (its mean luma), from integer sums, so both platforms read the same
numbers; `CaptureStability` takes a page held still only from a frame at least 40 sharp and 50 bright
(`Judge`; thresholds to be tuned on real phones), and `MarkCaptured` counts a page taken by hand as
taken. `DocumentEnhancer` cleans up a page cut out of a camera's photo: the paper's brightness
estimated in large tiles (a sixteenth of the page's long side, the 90th percentile of each), tiles
much darker than their neighbours (a picture, a black bar) filled from the paper around them unless
they reach the page's edge (then they are a shadow cast across the sheet and are evened out), each
pixel divided by the paper there, the paper's tint taken out (white balance from the paper's own
pixels), the levels stretched from the darkest print to white, in auto (color, or gray when nothing
colored is left), color, gray, black and white (threshold on the evened-out page, so print in a
shadow stays black), or photo (levels only, nothing evened out) mode. A page of light print on a dark
ground (a chalkboard, a dark flyer: `IsLightOnDark`) has no paper to even out against and is stretched
as a whole instead, then made gray or black and white as the mode says; the lit paper beside a hard
shadow's edge or a big dark picture is not taken for light print, so a short note under a shadow is
still evened out. `EnhanceStep` runs it in
`PageProcessor.ForCapture`, right after `PerspectiveStep`, once per page, in the task's color mode; a
page it made gray keeps that through the adjustments of a color task (`AdjustmentStep.ModeFor`).
`CaptureStability.Resume` takes the time the camera was stopped out of its clocks.
The bytes are pinned in `DocumentEnhancerTests` (golden checksums recomputed by an independent model
of the algorithm) and the readings in `FrameQualityTests`, the same cases as the Swift package.
**The Windows app does not use either yet:** "Import photos of documents" keeps its pages as cut out
(`PageProcessor.ForPhotoImport` has no clean-up step), and no window calls `ForCapture`; wiring the
clean-up into the desktop import is left for the desktop import of I17.

**Several objects in one shot, and glare (I13, shared with the iPhone app, no Windows screen yet).**
`CaptureObjects` turns the objects of one camera shot into pages: the task says what is photographed
(`KindFor`: photos for Photos and Restore old photos, receipts, the ID card, else pages), each object
becomes the photo as taken with its corners as its capture facts (`Pages`), so `PerspectiveStep` cuts
each out at the real size `CaptureScale` gives its kind (a print's size, a receipt roll's width, ID-1)
and `EnhanceStep` cleans it up for its kind (photos and cards as photos, never evened out); a shot in
which no outline was found comes in whole at 200 dpi (`FallbackPage`), for the flatbed's own searches
(`ReceiptDetector` finds thermal paper on a white table, `PhotoDetector` prints on a plain table).
`PageProcessor.ForCapture` now runs the photo import's steps (blank pages, separators, barcodes,
turning pages upright with text recognition) only for pages that go to the queue; the objects of
the other tasks get their adjustments alone, so an ID card is never read, and the shot they share
stays as taken (`AdjustmentStep` with `AdjustsAlternate` false). A card side that did not snap to
ID-1 is at a made-up size, and `CardNote` says so before any glare hint. `GlareDetector` measures
glare on a card or a print in the photo as taken: cells of the outline (less a band along its edges)
whose every channel is blown out (250 or more), and the largest patch of them side by side; a patch
of at least 1 % of the card is glare, which the iPhone says in one line ("Tilt to avoid glare"),
while white specks in the print are not. `PhotoReview.Title` and `SaveTitle` ("Found 3 photos",
"Save 3 photos") are the review's words on every platform; the Windows review uses them. The same
cases run in both suites (`CaptureObjectsTests`: the kinds, the pages, two prints cut out at 4 × 6 in,
the camera ID card composed at 85.60 × 53.98 mm within 0.5 mm, receipts and prints found in a whole
shot, the forCapture steps; `GlareDetectorTests`: readings pinned to an independent model). The
iPhone's own side (Vision's rectangles, the reviews, the guide frame) is Swift only.

**The camera's two-sided pages and book spreads (I14, shared with the iPhone app, no Windows screen
yet).** Two arrangements the Windows app never produces: `ScanArrangement.CameraFront` and
`CameraBack` mark the pages of the iPhone's two-sided camera with their side
(`DocumentSides.MarkCamera`), keeping a sheet given already and never turning a back for the binding:
the user turned the sheet over, and turning pages upright fixes one upside down. `PageProcessor` gains
`Prepare`, steps run on each arranged page before a spread is cut: `ForCapture` (with an
`arrangement` argument now) cuts a book's whole spread out of its photo and cleans it up first when
`SplitsCameraSpreads` (facing pages split and `TaskOptions.CameraSpreads`), then cuts it at its spine
as a scan's spread, its shadow softened after the blank check. The spread is cut out at its own pixels
(`PerspectiveStep(spread: true)` matches it against no sheet size, so it keeps the nominal 200 dpi rather
than snapping to a sheet it only looks like), and each page cut from it keeps the spread's `Source` and
`Capture`, so a page the clean-up made gray stays gray under the adjustments. `TaskOptions` keeps the camera's two
choices, `CameraFrontsFirst` and `CameraSpreads` (off unless chosen; the Windows app keeps them as
they are). The same cases run in both suites (`DocumentSidesTests`, `PageProcessorTests`,
`CapturePageTests`: a drawn spread on a table cut out at its own pixels and split near its spine, in
either reading order, 17 × 11 and √2 spreads that would snap to an ID card and A4 kept whole, and the
pages of a spread made gray kept gray; `BarcodeTests`: a photographed Patch T sheet snapped to Letter is a separator,
and a QR sheet's payload read on a photographed page splits and names the next document;
`ModelsCompatTests`). The camera's words, its two-sided steps, New document, Quick scan and the email
route are the iPhone's own (Swift only).

### Send from your phone

A phone with Lazy Scan sends what it scans straight into this PC's page queue. **Phone** (at
the bottom of the side pane) opens the phone window:

- **Pair a phone** shows a QR code to scan with the phone (Pair a computer, on the phone). The code
  works once and for 5 minutes, and five wrong tries close it. When a phone presents it, the window
  asks **Allow "Aytu's iPhone" to send documents to this PC?**; nothing is paired without Allow (no
  answer in 2 minutes counts as Don't allow; the question stays until it is answered). Without a camera, the address, the code and a
  six-digit check code are shown to type on the phone and compare.
- **Paired phones** lists each phone with when it was paired and last seen, and **Remove**: a removed
  phone is refused at once. **Reset pairing…** unpairs every phone and gives this PC a new key, so a
  phone that kept the old one can no longer connect.
- **Networks** lists the networks the PC is on and whether it receives there. It receives on networks
  Windows treats as **Private**, and on others only after **Allow receiving on this network** (for a
  network you trust but cannot set to Private, such as your school's Wi-Fi). It never listens on any
  other network, and nothing listens at all unless a phone is paired or a code is shown. On a network
  it does not receive on, Pair a phone says why instead of showing a code. On an allowed
  network that Windows treats as public, Windows Firewall asks once about Lazy Scan the first
  time it receives: tick **Public networks**, then **Allow**.
- **Connection checks** say why a phone may not connect: the network not received on, Windows
  Firewall blocking the app on a network it receives on (often after its question was cancelled: the
  rules to remove are named; a rule for another adapter, such as WSL's virtual switch, does not count),
  listening or why not, and that some networks (schools, hotels, guest Wi-Fi) keep devices from
  reaching each other, where the phone's hotspot or its share sheet helps instead.

Documents from paired phones are added to the queue **on their own**, labelled **From phone** in the
page strip, with a bar saying what arrived (the taskbar button flashes when the window is in the
background). A document sent as new starts a document of its own in the queue, under the name it
came with; one sent to the current document joins it. While the queue does not collect pages
(Photos mode, the ID card, copy and receipt tasks, **Collect pages before saving** off, a review open) or a scan runs, the document waits
and says so, and is added as soon as it can be. Pages the phone kept as photographed can be shown
that way with one click, as for imported photos. A `.lsdoc` opened from File Explorer (the app
registers the type for your user each time it starts), dropped on the window or picked with Import
photos is not added on its own: a bar offers **Add to pages** or **Open as new**.

When the network keeps the phone and this PC apart, the phone can put its documents, sealed with a
key only this PC and that phone hold, in a folder synced through OneDrive or iCloud Drive; the PC
watches that folder (`SyncFolderWatcher.cs`, `SyncPackage.cs`), adds them as if they had been sent
directly and deletes each file once it is in the queue. The folder is chosen under **Cloud folder**
in the Phone window, which also says whether it is being watched and names the last file it could
not read; when no paired phone has connected for three days and no folder is chosen, the connection
checks suggest one.

How it is kept safe: the phone and the PC talk directly (HTTP over TLS 1.2/1.3) with no server or
account in between. The PC's certificate (an ECDSA P-256 key of its own in the user's certificate
store, made the first time a pairing code is shown) is pinned by the phone from the QR code, so the first
connection is already checked. Each phone gets a 256-bit secret when it pairs; the PC keeps only its
SHA-256 (`companion-devices.json`), and every request without a paired phone's secret is refused
(401), except checking that the PC answers and pairing with a valid code. Uploads are checked in full
(every picture's checksum and format, see the `.lsdoc` package) before they count, are taken once
however often a phone retries, and are refused when too large; repeated wrong secrets or codes block
the sender for a minute. The PC advertises itself (DNS-SD, `_lazyscan._tcp`) only on the
networks it receives on and only while it receives, and the phone also remembers the address from the
QR code. Only one Lazy Scan window receives at a time.

### Rotate pages upright

**Rotate pages upright** (the inspector's **Pages** section, under crop and straighten) turns a
page put in upside down or sideways the right way up by reading its text with Windows OCR
(`WindowsOrientationScorer`: the recognizer of the user's languages, else the first installed).
It is off unless a task turns it on: the **Two-sided document** task does, since sheets go into a
feeder the wrong way round. Like crop and straighten it runs on pages collected in the queue only,
after the separator-sheet check and before the adjustments, and a page saved at once is never
turned, so the switch is greyed out then; without an OCR language it is greyed out too, and a
scan that should have turned pages says so. A turned page carries a small turn button at its top
right in the page strip, always shown ("Turned upright 180°. Undo turn."); one click turns it back
as scanned, and it is saved that way, and a second click turns it upright again. The turn is in
the page's spool files; undoing it goes through the page's rotation like a turn by hand, so the
two add up. The status after a scan says how many pages were turned (" 2 turned upright.").

How a page is judged (`OrientationDecision`): its lines of text, found as for straightening, say
which ways up are worth reading (as it is and upside down for lines across the page, a quarter
turn either way for lines down it, all four when that is not clear); blank pages, separator
sheets and pages with too little ink are not read at all. Each way up is read once, on a copy at
most 1600 pixels long, the likeliest first. A reading where at least 150 letters fall in words that
look like words, and words are at least 85 % of what was read, is taken at once, so an upright page
costs one reading; a clear reading of the page turned is taken at once only when the page was
already read the opposite way up (180° from it) and with twice the letters in words of every way
read before it, so a sideways page is always read both quarter turns. Otherwise every way worth
reading is read, and the way up with the most letters in words wins when it has at least 20 and
twice as many as any other way; anything closer is left as scanned. Text read upside down
still gives letters, but few words ("suo!umqxa", "RTtnJqoed"), which is what tells the ways apart.
No new reading starts after 3 seconds on one page, a reading that fails leaves the page, and Cancel
stops between readings.

Checked here with Windows OCR (en-US) on six public-domain scans behind the website's pictures (the
Clara Barton letter, typed, as archived and as laid on a lid; the Annie Oakley letter, handwritten
under a printed letterhead; the Thanksgiving menu's cover and inside; the menu laid on a lid), each
as it is and turned 90°, 180° and 270°: all 24 came out upright at 300 dpi and all 24 at 150 dpi.
With only a band across the middle of each page (a quarter of its height), 21 came out upright and
3 were left as scanned (the Barton letter's band turned, which reads 315 letters in words the right
way up and 178 the opposite way: not twice as many); none was turned wrong. Seven photos (a beach
scene, cabinet cards, postcards, houses), each turned all four ways, were all left as they were.
Time per 300 dpi page, reading included: 450 ms median, 770 ms at most (one reading for an upright
page, two for the others, four for the menu cover, whose decorative type gives no clear line
direction); at 150 dpi 250 to 350 ms median. Through the view model, six pages at 150 dpi took
between 100 and 250 ms more a page with the switch on (runs vary).
**To check on real hardware:** pages from real feeders put in the wrong way round, forms and
tables with little running text, pages in other scripts with the matching OCR language.

### ID card

The **ID card** task (flatbed only; greyed out on a scanner without one) makes a copy of an ID
card or driving licence with both sides on one page at real size. The banner guides three steps:
**Scan front** (the card face down near a corner of the glass, the lid closed), **Scan back** (the
card turned over where it lies; **No back side** when nothing is printed there), then the
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

The **Photocopy** task (any scanner; greyed out with "Needs a printer" when Windows lists no
printer) makes the scanner and a printer a photocopier: the main button is **Copy**, which scans and
prints straight away, at real size: a page scanned at 300 dpi prints at its pixels / 300 inches, 1
inch on the glass is 1 inch on paper, and nothing is scaled to the page unless **Fit to page** is on
(then it is made smaller, never larger, to fit the part of the paper the printer prints on, turned a
quarter when that makes it larger, and centered). The inspector's **Photocopy** section has the
**Printer** (the default printer unless another is chosen; a chosen printer that is no longer
installed falls back to the default, and choosing the default follows the default), its paper,
**Copies** (1 to 99), **Fit to page**, **Also save a PDF** and **Print test ruler**; color or grey
is the inspector's Color. On the glass with nothing selected and Automatic
paper size, the part of the glass the printer's paper covers is scanned from the corner, as a copier
copies the sheet it prints on; another paper size is asked of the printer too; an area selected on
the preview is centred on the paper; the feeder copies a whole stack. The status says what was sent
("Sent 2 pages to Office Laser, 3 copies.") and what the printer's margins cut off ("Edges may be cut
by up to 5 mm (printer margins).", or "Larger than the paper: …" for a scan larger than the paper);
the inspector says it before copying ("Edges may lose up to 5 mm", with a warning glyph, while Fit
to page is off). Copies are scanned like any scan (they are in the Scans
tab) but never queued or spooled, so they are printed as scanned: no page is left out as blank,
cropped or straightened (the Pages and Split sections are hidden for the task); **Also save a PDF** saves
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
Compact or Smallest (what each does is its tooltip), with a line under it saying how big the
last saved PDF was ("Last PDF: 498 KB"; the status bar's accessible name gives the exact size). `PdfImageEncoding` plans each page:

| Size | Page images at most | JPEG quality (color / gray) | Color pages without color | Black & white pages (CCITT G4) at most |
|---|---|---|---|---|
| Best | scan resolution | 0.90 / 0.90 | stay color | scan resolution |
| Standard | 300 dpi | 0.80 / 0.80 | stored gray | 600 dpi |
| Compact | 200 dpi | 0.65 / 0.70 | stored gray | 300 dpi |
| Smallest | 150 dpi | 0.50 / 0.55 | stored gray | 300 dpi |

Pages are downsampled (box filter) only when they are more than 10 % finer than the limit;
the page size in the PDF never changes, and text recognition reads the full-resolution page
first. Grayscale pages are stored as one-component JPEGs (`/DeviceGray`). Black & white pages
(the Black & White color mode, after its threshold) are stored as 1-bit CCITT Group 4 images
(`/CCITTFaxDecode`, lossless) at every size, in every PDF the app writes (plain, PDF/A, protected,
pages added to an existing PDF); a downsampled one is thresholded again (luma below 128 is
black). One bit per pixel needs more pixels than gray to keep text smooth, hence their own,
higher limit. A
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
pencil notes, 2550 × 3510 px), both saved as 300 dpi one-page PDFs through the app's save path
("Before" is the full-resolution RGB JPEG at quality 0.9 that every PDF held before PDF sizes):

| Page | Color mode | Before | Best | Standard | Compact | Smallest |
|---|---|---|---|---|---|---|
| letter | Color | 1.17 MB | 1.17 MB | 856 KB | 259 KB | 119 KB |
| letter | Grayscale | 1.11 MB | 1.07 MB | 778 KB | 263 KB | 111 KB |
| letter | Black & White, gray JPEG (until G4) | 694 KB | 655 KB | 527 KB | 216 KB | 122 KB |
| letter | Black & White, CCITT G4 | 694 KB | 33 KB | 33 KB | 33 KB | 33 KB |
| menu | Color | 1.48 MB | 1.48 MB | 905 KB | 309 KB | 160 KB |
| menu | Grayscale | 1.40 MB | 1.36 MB | 833 KB | 314 KB | 157 KB |
| menu | Black & White, gray JPEG (until G4) | 997 KB | 956 KB | 760 KB | 309 KB | 183 KB |
| menu | Black & White, CCITT G4 | 997 KB | 47 KB | 47 KB | 47 KB | 47 KB |
| menu with its color removed, scanned in color | Color | 1.40 MB | 1.40 MB | 833 KB | 314 KB | 157 KB |

Both real pages have color, so they stay color; the last row shows a color scan of a page
without color being stored gray. A black & white page is the same 1-bit G4 image at every size
for 300 dpi scans: 16 times smaller than the gray JPEG that Standard stored before (20 times at
Best), and still 3.7 to 3.9 times smaller than Smallest's 150 dpi gray JPEG, at twice its
resolution and without JPEG's halos around the letters. Scanned at 600 dpi, the letter is 58 KB at Best and Standard
(600 dpi kept; the gray JPEG was 1.63 MB and 472 KB) and 30 KB at Compact and Smallest (300 dpi;
217 KB and 119 KB before).

**Black & white TIFF files** are CCITT G4 too (compression 4, 1 bit per pixel, WhiteIsZero, the
scan's resolution; `BilevelTiff`, which also writes multi-page files): each scan saved at once,
the photos saved from the photo review, and the ID card's page and its sides. The letter is 32 KB
and the menu 46 KB, against 632 KB and 695 KB as the RGB LZW TIFFs they were. Turning such a file
in the Saved tab keeps it G4. Other TIFFs stay LZW: color and gray pages, and receipts, which are
always enhanced gray.

A page is stored in the color mode it was **scanned** in, not the one set when it is saved, so
only pixels the black & white mode thresholded at the user's level become G4: an ID card or photos
scanned in color stay color when the mode is switched to Black & White before saving (the card's
page is black & white only when both sides were; color when either side is color, else gray). A
book spread joined or split again is made with the current settings, color mode included: in
Black & White its pages are thresholded at the user's level, in Color with no adjustments they are
the spread as scanned and stored as color (or gray) JPEGs.

The size hint under the picker names both limits, for example "Up to 200 dpi (black & white
300), more compression. For email and uploads."; the Mac's hint is the same.

The encoder (`CcittG4Encoder`, ITU-T T.6, our own code with no library) codes each row the way
libtiff does, mode for mode: its output is byte-identical to WIC's own G4 encoder on every page
tried, the two real scans included. WIC decodes its TIFFs and PdfPig (test-only) its PDF images
pixel for pixel, and Windows.Data.Pdf renders its pages as it renders the same pixels stored as
a gray JPEG at quality 100.

### Archival PDF (PDF/A) and the text layer

**Archival PDF (PDF/A)**, in the inspector's Archive & password section, saves every PDF
as PDF/A-2b, the ISO format for keeping documents: the file carries its own color profile (sRGB),
its fonts and its description (title, dates, producer) in XMP metadata that matches the
document information, and an identifier. It works with every PDF size and every PDF the app
saves (collected pages, split documents, receipts, the ID card's page, a copy's PDF). The
**Archive document** task sets it up: 300 dpi color, Best size, searchable, PDF/A. Turning the
switch off, or choosing another format, ends the task; picking any other task turns it off.
PDF/A files cannot have a password: while **Require a password** is on, this switch is greyed out
with a lock and "Not with a password" next to it, and the other way round ("Not with PDF/A").

The invisible text layer of a searchable PDF now uses a tiny font embedded in the file, built
from code (`GlyphlessFont`): one empty glyph, half an em wide, for every character. Text in any
script can be selected, searched and copied: Turkish (ç, ğ, ı, İ, ö, ş, ü), Greek, Cyrillic,
Arabic, Hebrew, Chinese, Japanese, Devanagari and characters beyond the Basic Multilingual
Plane, where earlier versions wrote "?" for anything outside Latin-1. Each line's text fills
the box OCR found for it, so a selection covers the printed words. The color profile is
sRGB-v2-magic from [Compact-ICC-Profiles](https://github.com/saucecontrol/Compact-ICC-Profiles)
by Clinton Ingram (CC0 1.0, 736 bytes), stored in `PdfA.cs`.

Checked here: the structure, the XMP and Info dates, and the text layer read back through PdfPig
(`PdfATests`, `GlyphlessFontTests`); the saved files opened by Windows' own PDF reader
(`Windows.Data.Pdf`), the font read by DirectWrite (two glyphs, half an em, installable).
veraPDF is not installed on this PC; CI validates PDF/A files instead: the Windows job keeps the
files `PdfATests.Archival_ValidationSamples` writes (it does so when `LAZYSCAN_PDFA_SAMPLES`
names a folder) and runs veraPDF 1.30.3, downloaded in CI only and pinned by its SHA-256, on them
with `--flavour 2b`. Run `verapdf --flavour 2b` on a saved file where it is installed.

The Mac has the same switch, task and files: its Swift port of this writer (`PDFA.swift`, with the
same profile bytes pinned by SHA-256) writes the same PDF/A file byte for byte (the golden file
`PdfATests.Archival_GoldenBytes` pins is checked by `PDFATests` too), and CI's macOS job runs the
same pinned veraPDF on the files the Swift writer makes.

### Password-protected PDFs

**Require a password**, under the archival switch in Archive & password, makes every PDF the app saves
open only with a password (collected pages, pages saved as they are scanned, split documents,
receipts, the ID card's page, a copy's PDF; the separator sheet is not a saved document). The
password is asked for when saving, in a dialog that asks for it twice, says how hard it is to
guess (a bar of four segments with "Weak · use 12+ characters", "Fair · longer is safer" or "Strong"; the full
advice is the tooltip: a rough guess from its length and the kinds of characters in it), keeps its
warning in view ("It can't be recovered if forgotten. Every PDF you save now gets it.") and offers
**Allow printing** and **Allow copying** (text and images; both on). While it is on, the Save
button carries a lock and the collapsed Archive & password header says "Password on". It is asked for once
per save and used for every file of that save; the next save asks again. It is never stored:
settings and presets keep only the switch (`"protect": true`), and nothing about it goes to
logs, `devices.txt` or the Saved list. The dialog's boxes are emptied when it closes, the
prepared password bytes and each file's key are wiped when the save ends (the text typed lives
in .NET strings until the garbage collector reclaims them; that cannot be wiped). Cancel in the
dialog saves nothing: collected pages stay in the queue, pages scanned while saving as they are
scanned go to the queue, a split save writes no document. A copy that also saves a PDF asks
before printing: Cancel still prints the copy, and when the printer then fails the pages go to the
queue. The status after a save says "password-protected" (split documents and receipts too; the
separator sheet never is).

The file is PDF 1.7 with the PDF 2.0 standard security handler at its current level (`/V 5 /R 6`,
AES-256, Adobe extension level 8 declared): every stream and string encrypted with AES-256-CBC
under a random file key of its own, the password checked through the SHA-256/384/512 hash of
ISO 32000-2 algorithm 2.B, the password prepared as PDF 2.0 asks (SASLprep's mappings, NFKC,
UTF-8, at most 127 bytes). The owner password is 32 random bytes nobody knows, so the
permissions apply to everyone who opens the file, with one exception: the Mac's PDFKit (Preview,
the Mac app) passes a typed password on decomposed ("Ş" as "S" and a combining cedilla) and
tries no other form, so for a password with such a character the owner password is that
decomposed form, and PDFKit opens the file as its owner, without the permissions. **The
permissions are advisory:** most PDF apps honor them, but anyone with the password can print or copy with software that ignores
them; the dialog says so. A PDF/A file cannot be encrypted, so the two switches exclude each
other (a settings file with both on gets the password), the Archive document task turns the
password off, and `PdfBuilder` refuses options that ask for both.

Checked here: algorithm 2.B and the file key against the PDF 2.0 known answers of pdf.js's
crypto tests, a SASLprep case and a dictionary whose /P no longer matches its /Perms; the values
for a fixed password and fixed random bytes, also computed by a separate implementation written
from the standard; every stream and string decrypting back; the files opened by PdfPig with the
password and refused without it or with a wrong one (`PdfEncryptionTests`); and by driving the
view model with the demo scanner (one question per save, a split stack, Cancel, saving as
scanned, the Archive document task, no password in any of the app's files) and building the
window and the dialog without showing them. **Windows' own PDF renderer (`Windows.Data.Pdf`)
does not open AES-256 revision 6 files at all**, ours or anyone's: it fails with 0x80048040 on
reference files made by qpdf, with the right password, while it opens revision 5 and AES-128
files. The Saved tab therefore shows the PDF icon for a protected file, as it would without the
password anyway. PDF apps that support revision 6 (Adobe Acrobat and Reader, the viewers built
into Edge, Chrome and Firefox) should open them; none was tried here, as checks must not open
other apps. Not run here: qpdf (not installed).

The Mac protects its PDFs the same way: the Swift twin (`PDFEncryption.swift`, CommonCrypto's
AES and CryptoKit's SHA-2) gives the same values and the same file for the same password and
random bytes (`PdfEncryptionTests.Protected_GoldenBytes` is checked by `PDFEncryptionTests` too),
and its PDFKit opens the files only with the user's or the owner password, on the Mac and in the
iOS Simulator, including passwords with accented letters. Its dialog is a window of its own with
the same texts, strength bar and checks.

### Add pages to an existing PDF

**Add to existing PDF…**, in the menu of the Save button's ▾,
picks a PDF (the picker opens in the save folder) and adds the queued pages to its end; so does
**Add the scanned pages to this PDF** in a PDF's menu in the Saved tab. The pages are the ones
the queue would save (pages skipped by hand, blank pages and separator sheets stay out; a split
queue goes in as one run, in order), stored as the PDF size and the text layer settings say. The
file then shows in the bar after a save, with its new page count and size ("Added 2 pages to
Contract.pdf (now 11 pages, 1.4 MB)"), and the after-save action runs. The target is chosen
each time and never stored.

The pages are added as an **incremental update**: the file's bytes stay exactly as they were,
and after them come the new pages (with their own copy of the text layer's font), the page
tree's root again with the new pages added, and a cross-reference section of the same kind as
the file's newest one, pointing back at it. `PdfReaderLite` reads what is needed for that:
classic tables and cross-reference streams (Flate with PNG predictors), files already updated
by other apps, hybrid files (as Microsoft Word writes them), objects inside object streams, page
trees of any shape. The new pages say their own size, resources and rotation, so nothing the
file's page tree passes down to its pages (a rotation, a crop box) changes them.

Nothing is changed in place: the original and the update are written to a hidden temporary
file in the same folder, which is read back (the original's bytes unchanged at its start, the
update pointing at the original's last section, every page there) before it takes the file's
place with Windows' ReplaceFile, which keeps what belongs to the file rather than to its bytes:
its creation time, its permissions, its alternate data streams (such as the Zone.Identifier mark
of a file downloaded from the internet, so it still opens in Protected View) and EFS encryption.
Other hard links to the file are not kept: they still show the old content, without the new
pages. The original is moved aside under a backup name (`.{guid}.pdf.bak`, with the original's
own attributes) for that moment and removed after (hidden and left when it cannot be removed).
If the updated file then cannot take the name, the original is moved back; should that fail too,
it is left unchanged under the backup name, and the refusal names that file so it can be renamed
back. Where the file system has no ReplaceFile, one rename over the file keeps only its creation
time and attributes. The file is held open meanwhile, so no other app can change it half-way. Refused,
with the pages left in the queue (what is wrong with the file itself is found before any OCR
runs): a **password-protected** file ("Save
them as a new PDF instead"), a **damaged** one (cross-reference data or objects that do not hold
up, also ones read only when asked for such as the form or the output intent; a page tree whose
root is a page; object numbers past PDF's limit of 8,388,607: the reader never repairs or
guesses), one with bytes before its header, a compression it cannot undo or no object numbers
left for the new pages, a **read-only** file or one in a folder that takes no new files, a file
**open in another app** ("Close it there, then add the pages again"), and a disk too full for the
updated file. Every refusal is a sentence for the user, never the reader's own detail. A
**signed** file is asked about first (the signature stays, but PDF apps show that the file
changed after signing), a **certified** one too, with a stronger warning (no certification
allows adding pages, so PDF apps show the certification as no longer valid), and so is a
**PDF/A** file whose level
the new pages may not keep: PDF/A-1b, -2b, -2u, -3b and -3u files with an RGB output intent stay
PDF/A (the new pages carry an embedded font and JPEG images the intent covers, and the update
keeps the file identifier, metadata and document information), the others are asked about. The
password and archival switches are for new files: the file decides, so a file without a password
gets pages without one, and the status says so when the switch is on.

The Mac and the iPhone write the same incremental update with the Swift twins of the reader and
the appender (`PDFReaderLite.swift`, `PDFAppender.swift`).

The start screen's "Add pages to a PDF" tile asks for the PDF first and then sets up Document to
PDF: Save reads "Add to Contract.pdf", with the file's path and a × under it to save a new PDF
instead, and adds the scanned pages to that file. Picking another task or a preset forgets the file.
**Collect pages before saving** is greyed out while the file is picked, and its tooltip and help text
say why: with it off each scan would be saved as a new file.

**Not done yet** (from the M21 spec): the picker showing the chosen file's first page. (The split
button is there now: Save with Add to existing PDF… in its ▾ menu; instead of a "Save as new PDF"
item, the × under Save goes back to new files while a picked PDF takes the pages.)

Checked here: `PdfReaderLiteTests` and `PdfAppenderTests` (hand-made fixtures for each
cross-reference layout, page-tree shape and refusal, and our own plain, PDF/A and
password-protected files), every result read back by PdfPig with its lenient parsing off; files
made by other apps (Skia, Figma, a Word file with object streams and a hybrid cross-reference,
and pdf.js's encrypted test files, which are refused) given pages and then read by PdfPig and
rendered by Windows' own PDF reader (`Windows.Data.Pdf`); and the view model driven with the
demo scanner (adding to a saved PDF, the refusals, a signed file's question, the password switch
on a PDF/A file, skipped pages and the after-save action) with the window and the Saved tab built
off screen. CI runs veraPDF on a PDF/A file with pages added twice. Not run here: qpdf (not
installed).

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

**After saving** (in the inspector's More options section, and next to the photo review's Save
button) runs one of these on its own once a save has finished: **Do nothing** (the default),
**Open**, **Show in folder** or **Share…**. Several files are shown in their folder rather than
opened one by one. A cancelled or failed save runs nothing, and a file that has been moved or
deleted since is reported instead. Picking a task sets it: the **Email a document** task shares,
the others do nothing; choosing another action ends the Email task. The choice is decided in Core
(`SaveActions`: the plan, the actions offered, what Copy puts on the clipboard, the email route)
and carried out by `Services/FileActions.cs` and `Services/ShareService.cs`, which the view model
takes as a stand-in in checks.

### Text: Word documents, text files and Copy Text

For editable text rather than a picture of the paper:

- **Format** (inspector, Output) offers **Word (.docx)** and **Text (.txt)** for documents, next
  to PDF and the image formats; Photos offers the image formats only (a PDF or text format chosen
  for documents shows as JPEG there and is kept). With the pages collected, the queue's button
  becomes **Save Word** or **Save Text** and writes one file with the text of every page; a scan
  saved at once is written as its own Word document or text file. The ID card's page is a PDF or
  an image whatever the format says.
- **Also save text (.txt)** (inspector, More options) writes a text file with the PDF's name next to
  every PDF of a document saved (the next free name when that one is taken; nothing is ever
  replaced). It is hidden when a save writes no PDF, and in the ID card and Copy tasks, whose PDFs
  are pictures of a card or of a copy. Picking a task turns it off.
- **Scan to Word** on the start screen: 300 dpi, color, pages collected, saved as a Word
  document. Choosing another format ends the task.
- **Include page images** (inspector, Output, for Word): each page of the Word document starts
  with the page as scanned, then its text. On by default, also for settings saved before it
  existed; picking a task keeps the user's choice. With it on, the size picker shows as **Page
  image size**: the pictures are stored as that PDF size stores a PDF page (its resolution limit
  and JPEG quality, gray pages as gray JPEGs), and a black & white page as a lossless 1-bit PNG
  (the G4 page of a PDF). Off, the document is the text only, byte for byte as before. A Word
  document that would be larger than 2 GB is not written: the save fails saying so (as soon as
  the pictures alone pass 2 GB, without reading the remaining pages) and the pages stay queued.
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

With page pictures, a page's picture comes first, in a centred paragraph of its own with no space
around it: one inline DrawingML picture (`wp:inline`, `a:graphic`, `pic:pic`), the page's real
size or shrunk with its shape kept to fit inside the margins (sizes in EMU, 12,700 a point,
rounded down), named "Page n" for screen readers. A full page then fills its sheet and its text
starts on the next; a small page (a receipt) keeps its real size with its text under it. Inline
pictures were chosen over a picture behind the text or text boxes laid over the scan because
they read the same in Word, LibreOffice, Pages and Google Docs and stay put while the text is
edited. The pictures are `word/media/image1.jpeg` (or `.png`) and on, linked from
`word/_rels/document.xml.rels` as `rId1` and on, with `[Content_Types].xml` giving `image/jpeg`
and `image/png` only when used; all entries stay stored (the pictures are already compressed), so
a document is about the size of its pictures, close to the PDF of the same pages at the same size.

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
  with **One PDF for all** (inspector, Receipts).
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

### Separate documents

**Split into documents** (the inspector's section of that name; its ⓘ says how each way works)
saves the collected pages as several files: **At separator sheets**, **At blank sheets** or **Every
N sheets** ("New document every [N] sheets", 1 to 99 in the list, up to 999 in a settings file). The **Separate documents** task (feeder only; greyed out on a scanner without one)
sets it up: 300 dpi, PDF, split at separator sheets, blank pages skipped, named
`Document {label} {date} {counter}`. The other tasks do not split; the sheets per document are
kept. Like the blank-page check, splitting needs the pages collected in the queue, so the choice is
greyed out ("Needs Collect pages") when each scan is saved at once; the section is hidden for copies
and receipts.

- **Separator sheets**: **Save sheet** (shown with At separator sheets) saves a
  Patch T sheet as a one-page PDF in the scans folder, "Separator sheet (Patch T, Letter).pdf" or
  A4 where that is the usual paper, to print at actual size (100%) on any printer, also on another
  computer; it needs no printer here, and the saved bar opens it. **Print sheet** prints
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
- **Every few sheets**: a sheet is a front with its back; blank sheets count too.

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
what is left out ("7 pages · 3 documents · 2 separator pages skipped"), the status after a
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
photos and a sheet on a backdrop.
**To check on real hardware:** separator sheets printed on real printers (toner spread, a printer
that shrinks the page), feeders that skew sheets more than 3°, and very dark or colored paper.

#### Barcode and QR separator sheets

**At QR codes or barcodes** splits the stack at separator sheets carrying a QR code, Code 128,
Code 39 or Data Matrix code (other kinds are not looked for) whose text starts with `LS-SEP`, the
separator prefix the app's QR sheets carry ("LS-SEP Lease 2026"): a sheet with such a code on either
side is a separator, left out like a patch-code sheet, and the rest of the code's text names the
document after it (`{label}`; when several such sheets are in a row the last one names it). Other
codes are ignored, so a payment QR code or an order number printed on an invoice never makes its
page a separator. The prefix is compared with a–z matching A–Z, after any spaces or byte-order mark
the code starts with; it is the settings field `splitBarcodePrefix` (kept in settings files and
presets, with no inspector field; an empty one makes every code a separator code). The text becomes
a name as a typed one would: invisible format characters (byte-order marks, zero-width spaces,
bidi overrides that would reorder a file name in Explorer) are dropped, control characters and runs
of spaces become one space, the characters file names can't have (`/ \ : * ? " < > |`) a hyphen,
and it is cut at 100 characters; a sheet whose code is the prefix alone only splits. A name typed in
the page strip wins over the code's, and removing it brings the code's back. **Codes are on: First pages** (shown with this split; the
default is **Separator sheets**, and the line under it says "Sheets are left out" or "Pages are
kept") keeps the pages with a code instead, any code:
each starts a new document named after its code (without the prefix when it has it), for documents
that carry their own code, such as invoices or forms; a click on the gap joins one back. The page
strip shows all of this before saving, as for patch codes; a separator page's tooltip names the
sheet's code, read on either side, and the document the plan starts after it ("Separator sheet (QR
code “LS-SEP Lease”): a new document named “Lease” starts after it. It is not saved."; when two
code sheets are in a row, both name the document the last one names; when the page after a
separator is joined to the document before, the tooltip says so instead). Separator pages are not
saved, and a successful save clears the queue and deletes the spool files of every page in it,
separator pages included: a page wrongly taken for a separator has to be kept in the strip (Keep
this page) before saving.

**Save sheet** and **Print sheet** (shown with this split while codes are on separator sheets)
make the sheet to print, with the name typed in **Name on sheet** (optional):
"SEPARATOR SHEET", the QR code of the prefix and the name ("LS-SEP Lease 2026"; 2.5 in at most, UTF-8 so names in any script read back, error
correction level M), "THE NEXT DOCUMENT IS NAMED" and the name in the sheet's dot type (accents
dropped; characters it does not have show as "?", while the code keeps the name exactly), and how to
use it, saved as "Separator sheet (QR code, Lease 2026, Letter).pdf" or printed at real size on the
printer chosen for copies. A QR code reads at any size and either way round, so the sheet need not
be printed at 100 %.

Barcodes are read only while this split is chosen (reading takes about 0.1–0.5 s a page; a page
with no code is the slowest, since every pass runs on it). No task chooses this split; choosing it,
by hand or with a preset, reads the pages already queued that were never read, each on its
full-resolution spool file (`BarcodeSeparators.ReadQueuedPage`), not on the preview the queue keeps
(about 145 dpi for a letter page and 114 for legal, too coarse for 1D codes of 0.010–0.013 in a
bar), with the count read in the status bar and the progress bar. Other settings edits start no
reading. A page with no spool file is read on its preview, and when that shows no code it is left
unread rather than taken as one without. Cancel keeps what was read and says how many pages were
not; those are read after the next scan or when the split is chosen again. A page the reader fails
on is not read again until the split is chosen again. The reading (`ZXingBarcodeReader`, ZXing.Net in the
app only, behind Core's `IBarcodeReader`) works on the page's gray copy at 200 dpi
(`BarcodeSeparators.ReadingDpi`; a coarser scan as it is): the codes found on the image, then, when
none was, on the image at half resolution (where the noise inside a large code's modules is averaged
out; ZXing's local threshold otherwise breaks them up), then, when still none was, on likely Data
Matrix spots one at a time (cells a quarter inch across about half dark, read in a 2 in window
centred on each and again enlarged twice, since ZXing finds a Data Matrix code only around the middle
of the image it is given). The first code in reading order (top to bottom, then left to right) is
the page's. Checked by `LazyScan.App.Tests/BarcodeReaderTests.cs` on synthetic scans (codes
drawn by ZXing at their printed size, scanned at 150, 200 and 300 dpi with noise and a ±3° slant):
each kind, Data Matrix in every corner, several codes in reading order, no code on blank pages,
pages of text or the patch-code sheet, the QR sheet with names in Latin, Turkish, Greek and Japanese
read back exactly, also from a queued page's preview, small 1D codes (Code 39 at 0.010 in on letter
and 0.012 in on legal, Code 128 at 0.010 in on legal) that a queued page's preview loses read from
its spool file, the demo's Code 39 sheet at 100–300 dpi (its bars the same as ZXing's), and a stack split and
named end to end through the clean-up stage, an order number on a document's page ignored. Long
rectangular Data Matrix codes (which ZXing makes for short texts unless asked for square ones) are
found less reliably than square ones.
**To check on real hardware:** QR sheets printed and fed through real scanners, codes printed by
other software, small 1D codes below 0.012 in a bar, and the Mac (Vision) with real scans.

### Book or magazine

**Split facing pages** (the inspector's **Pages** section, under Rotate pages upright) cuts each
scan of an open book or magazine at the spine into its two pages. The **Book or magazine** task
(flatbed only; greyed out on a scanner without one) sets it up: 300 dpi, color, searchable PDF,
each page straightened and turned upright on its own, named `{task} {date} {counter}` ("Book
2026-10-19 3.pdf"), and the banner asks for one spread at a time ("Open the book face down with the
spine in the middle of the glass and press it gently flat, then scan. Turn the page and scan the
next spread; each one becomes two pages."; the button says **Scan spread**). Turning
**Split facing pages** or **Collect pages before saving** off ends the task. Color is the default
because the Standard PDF size already stores pages that are really gray in gray, and magazines keep
their color. The switch works for any collected document scan of one side of each sheet; with each
scan saved at once and for two-sided feeder scans (whose pages are paired by sheet and side) it is
greyed out with the reason ("Needs Collect pages", "Not with two-sided"); for copies and receipts
the Pages section is hidden. A spread whose spine was not found is badged **Not split** in the page
strip, with **Split…** to place the cut by hand. While it is on, **Reads right to left**
(Arabic, Hebrew, manga: the right page first), **Book rotation** (as scanned, 90° clockwise,
180°, 90° counterclockwise, for a book lying sideways or upside down) and **Soften spine shadow**
show beneath it; the first two are kept when a task is picked, and all three apply from the next
spread on (and to a spread joined or split again).

The split runs in the page clean-up stage (`PageProcessor`), before the other steps, so each page is
checked for being blank, straightened and turned upright on its own. The two pages are put in
reading order by where they lie once turned: by the book's rotation plus the turn reading their text
gave them when the two pages agree (or when only one was read): left before right, right before left
reading right to left, top before bottom. Each page in the strip is labelled with its spread and
side ("2 · left", read out "Spread 2, left page"), the side worked out when the spread was cut, so a
page keeps it when moved, when its partner is removed, and when the reading order is changed for
later spreads; a spread whose spine was not found stays one page, "2 · not split", and the status
after the scan says so ("The spine of 1 spread was not found: it was added as one page (Split… on it
splits it)."). A page's right-click menu has **Split this spread…** (for a
spread kept whole) or **Change the split…**, which opens a dialog with the spread as scanned and the
cut drawn across it: click or drag on the spread, or use the slider or the arrow keys, choose
**Side by side** or **Stacked**, then **Split**; **Keep as one page** and the menu's
**Join the two pages** make the spread one page again. Joining or splitting again starts from the
spread as scanned, kept in the page spool (`<id>-spread.png`) until its last page is removed, saved or
cleared, and runs the clean-up again with the current settings. A split moved keeps what was decided
about each page (its document break, document name, and keep or skip) and leaves out a page that was
removed from the queue; a join, or a first split, gives the first new page the break of the spread's
first page and the first name among its pages, and every new page the keep or skip they shared.

How the spine is found (`BookSplitter`), on a gray copy at 100 dpi, at most 1000 pixels long: along
each axis, over the middle 80 % of the other, two profiles, the mean gray and the share of
neighbouring pixels across the axis that differ by an ink edge (text), smoothed over 0.05 in, are
searched between a quarter and three quarters of the axis. **The spine's shadow** is a darkest point
at least 8 % darker than the paper beside it, at least 0.08 in wide (where it darkens the paper by
4 %; a thin dark line of page edges in it does not count against it) and at most 12 % of the axis
wide at half its own depth, with no text at its bottom and text within 1.5 in beside it; with text
on both sides it must lie near the middle of the spread's text (the pages of a book mirror each
other, a dark picture or a crease inside one page does not), and beside a blank page it must be at
least 15 % deep. **Without a shadow**, the blank run between the two pages' text counts when it is
at least 0.6 in long (two inner margins, wider than the gap between the columns of one page), bright
as paper, in the middle of the spread's text, with text on both sides. A gutter the text runs along
(a section gap, a letter's fold) is not a spine: which way the text runs is judged with the band
around the candidate blanked out, so the spine's own dark line does not fool it. The cut is the
middle of the shadow's bottom, or of the blank run, scaled back to the scan; anything unclear leaves
the spread whole.

Checked here (`BookSplitterTests`, and an evaluation run): on a real public-domain spread, the inside
of a ribbon-bound 1917 Thanksgiving menu (National Archives 285093956, Truman Library), the fold was
found at all four turns, 0.02 in and 0.01 in from where it is; nine real public-domain single pages
(letters by Clara Barton, Annie Oakley, Wilbur Wright and Cleveland Abbe, two menus, the menu's cover,
a 1973 photograph), each turned four ways, were never split (0 of 36). Spreads made of two of those
real pages, each cut out of its scan and joined with a spine shadow, were split in 11 of 12, all
within 0.09 in; joined without a shadow (pages whose margins do not mirror each other) all 12 stayed
whole. On 240 synthetic books (pages of text, the book anywhere on the glass, 30 % of them lying
sideways, shadows from none to 70 % deep, inner margins 0.15 to 0.8 in, some with a blank page),
207 were split, every one within 0.08 in of the spine (mean 0.013 in, 95 % within 0.05 in): all 141
with a shadow of 20 % or more, 20 of 25 with a fainter one, 44 of 45 with inner margins of 0.6 in or
more and no shadow; the rest (tight margins without a shadow, a blank page without one) stayed
whole. 160 synthetic single pages (one or two columns, section gaps, pictures, letters folded in
three) were never split. The demo book is cut at its spine to the pixel. Finding the spine takes
about 50 ms at 100 dpi and 120 to 240 ms on a 300 dpi spread. Curved pages near the spine are not
flattened.

**Soften spine shadow** (on for the Book or magazine task, off for every other task and for settings
files written before it existed) lifts the shadow along the spine on each page cut from a spread
(`SpineShadow`, a step of the clean-up stage after straightening and before the separator check).
The edge along the spine is the edge of the cut, turned with the page by **Book rotation**; a
spread kept whole is left alone. The shadow is measured from the paper itself, on a gray copy at 100
dpi: in the band up to 1.5 in from the spine (at most half the page), in blocks of rows 0.3 in long,
the paper's brightness at every distance from the edge (the 90th percentile of three columns, so the
paper between the text counts, not the ink) is divided by the paper's brightness just past the band.
The blocks that show the shadow (darker near the spine, paper again at the far side of the band; at
least 30 % of them, since a small book leaves the lid above and below it) agree on it, their median;
a block darker than that (a picture, a tint, a dark lid) takes the shadow of the blocks above and
below it, from the edge out to where it differs, a lighter one keeps its own, and the shadow is
smoothed across the rows and along the edge. A shadow is softened when it darkens the paper by at
least 4 %, is deepest within 0.25 in of the spine and fades before the end of the band, gradually:
from a quarter of the way back to the paper to within 2 % of it takes at least 0.04 in (a tint, a
thumb index or a bleed printed all along the spine comes back in a step, and is left as printed).
Every pixel is then divided by the shadow there (red, green and blue alike, so the paper keeps its
tint), leaving a 2 % margin and brightening at most 2.5 times: paper comes back to white and ink
keeps its share of the paper's light, so text keeps its contrast. Pictures beside the spine (dark or
mid-tone areas once thin strokes of text are taken away, at least 0.3 in square) keep every pixel at
any resolution (on a finer scan their box reaches one 100 dpi pixel further, since a picture's edge
can fall inside one), the gain fading in over the 0.06 in beyond it. Nothing past the band
changes. A softened page keeps the page as scanned as its other version: the arrow on the page shows
it as scanned and back, like a cropped or straightened page ("Spine shadow softened", "Straightened
1.2°, spine shadow softened"), and the status after a scan says "Spine shadow softened on 2 pages.".

Checked here (`SpineShadowTests`, the same cases and bytes as the Mac's, and an evaluation run): on
a synthetic book page with a shadow 0.8 in wide, 45 % deep at the top of the spine and 30 % at the
bottom, the paper within 0.8 in of the spine goes from 13.2 % darker on average to 1.9 %, and within
0.1 in of it from 33.6 % to 2.5 % (the worst column, the one at the spine, 3.3 %), the same at 300
dpi; the text keeps its contrast to within 0.1 % (ink against paper 0.837 without the shadow, 0.838
softened). Over 20 synthetic pages with shadows 10 % to 60 % deep and 0.3 to 1.4 in wide, the paper
ends up within 1.4 % to 3.2 % of the page without the shadow on average (2.0 % to 5.3 % within 0.1
in of the spine, from 6 % to 47 %), and on the 16 with text inside the shadow contrast is kept to
within 0.2 %. A textured picture 0.2 in from the spine and a flat gray band reaching it keep every
pixel (0 levels changed), scanned at 100 dpi and at 200 to 500 dpi, while the paper around them is
softened as elsewhere; so do textured and flat pictures (gray 90 to 200) whose edges fall between
the 100 dpi pixels (scanned at 150 to 500 dpi and moved 1 to 4 pixels). Pages without a shadow, a shadow of 3 %, a dark picture all along the spine,
a dark stripe 0.5 in from it and a flat bar 0.03 to 0.2 in wide printed all along it (gray 235 to
60, with a sharp edge or one blurred over 0.03 in, at 100 and 300 dpi) are left alone, while a
shadow 0.15 in wide and 8 % deep is still softened. On the real public-domain menu spread above, the
fold darkens the paper by 1 % to 3 % (pressed flat), so both pages are left alone; with a known
shadow (45 % to 30 %, 0.8 in) laid over each real page, the paper near the spine goes from 12.7 %
and 12.8 % darker to 1.2 % and 2.2 % (within 0.1 in of it, from 33 % to 1.3 % and 3.0 %), the ratio
of ink to paper is back to the real page's (left page: 0.216 as scanned, 0.165 shadowed, 0.216
softened; right page: 0.327, 0.336 and 0.326), and a real photograph (National Archives 548697,
1973) placed beside the spine, framed or not, touching the spine or not, keeps every pixel (the
paper right beside it is softened less: within 0.1 in of the spine 7.5 % remains). The demo book,
which covers half the glass, has both pages softened. Softening a 300 dpi page takes about 30 ms, a
600 dpi page about 100 ms.
**To check on real hardware:** real books with deep, uneven shadows (a thick spine lifted off the
glass at one end), magazines with photographs and tints bleeding into the gutter, and colored paper.

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
  a tip otherwise), or would not start; and drivers installed only for 32-bit apps, named by file,
  while the 32-bit helper reaches none of them, with why and what to do (the 32-bit .NET runtime
  missing, the helper missing, no 32-bit Data Source Manager, or one that lists no usable driver).
  Once the helper reaches a driver, they are listed and count as TWAIN drivers, and none is named
  any more: which file a source came from is not known.
- **The automatic network search** (DNS-SD) and how many scanners it found, and each address
  added by hand that does not answer, with why.
- **Tips** that always apply: a USB scanner needs its maker's driver and a direct cable
  (**Open Windows scanner settings**, `ms-settings:printers`, shows whether Windows sees it);
  wake the scanner; some scanners work only with their maker's app.

**Refresh** asks every connection to look again: WIA lists its scanners, eSCL checks the addresses
added by hand and restarts a network search Windows had stopped (only the stopped one; the scanners
it had found stay listed, and those its new search does not find again are dropped after its first
pass), and TWAIN lists its drivers again when it was missing or would not start (while TWAIN works
its list stays as it is). A Refresh while one is running is ignored. A selected scanner that could
not be connected to is opened again, unless that would end a scan, a review or an ID card's sides.
The checks are made again as the scanner list changes. **Copy diagnostics** copies the checks and
the device list
(the same text as `%LOCALAPPDATA%\Lazy Scan\Logs\devices.txt`, which now ends with the
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
| WIA backend (`WiaScannerBackend`) | **Experimental, untested against hardware** — documented WIA Automation flow; every WIA call (enumeration and scanning, from every connection and window) runs on one STA thread of its own, one at a time, because WIA Automation used from two threads at once hands its objects across apartments and can crash the app (`WiaApartment`, stress-tested by `WiaEnumerationTests`); without a running WIA service (`stisvc`) or a registered WIA Automation it creates no WIA object, lists nothing and devices.txt says why (`WiaAvailability`); enumeration runs off the UI thread and re-polls (every 10 s backing off to 60 s while no scanner is present, every 60 s while one is), so scanners plugged in or unplugged later show up without a restart. The sources come from the device's document-handling capabilities, so a feeder-only scanner offers no flatbed and no preview; the feeder's sheet size and two-sided support are reported; two-sided feeder scans select FEEDER, DUPLEX and FRONT_FIRST (without FRONT_FIRST for a driver that refuses it, the feeder alone, one side, for a driver that refuses two-sided feeding, which the app is told) and every sheet (`WIA_DPS_PAGES` 0); a driver that takes no feeder selection at all scans the feeder only when it is already selected (single-source drivers can make the selection read-only), with the sides it has selected, and otherwise fails rather than scanning another source; a feeder paper size is set through `WIA_DPS_PAGE_SIZE` (the custom size and width/height for sizes WIA has no name for) and the item's extents; a feeder batch uses one connection; WIA error codes become plain messages (an empty feeder says "Load paper in the feeder, then scan again."); a batch that fails partway keeps the sheets already scanned and tells the user how many were kept and why it stopped. Expect to iterate with a real scanner attached |
| Windows Scan backup connection (`WinRtScannerBackend`, `WindowsScan`) | **Experimental, untested against hardware** — see [Windows Scan](#windows-scan-backup-connection) below. The decisions in Core (capabilities from each source's reported bounds, the scan request: resolution, color mode, file format, area, paper size, two sides; error mapping, which failures hide the connection (one scanner refusing to open does not hide the others: `WindowsScanAccess`), the feeder area a scan of a feeder of unknown size puts back, page order of a partly scanned batch, the diagnostics) are covered by `WindowsScanTests` and the `FromBounds` cases of `ResolutionListTests`; `WinRtScannerTests` check the Core enums against the WinRT ones, the paper sizes against `PrintMediaSize`, and run the real device watcher. Checked on Windows 11 without a scanner, in this unpackaged app: the watcher's first pass completes in about half a second with no scanner listed and `devices.txt` says "Windows Scan (backup): watching, 0 scanner(s)"; opening a device that is not there reports an offline scanner (`WIA_S_NO_DEVICE_AVAILABLE`), not a refusal of the API. Driving the view model with stand-in WIA and Windows Scan entries for one scanner checked one row "via WIA", the chooser offering "Windows Scan (backup)", choosing it and Automatic again, the backup taking over when WIA stops listing the scanner (captioned "Windows Scan (backup)") and WIA taking back over when it lists it again, and the watcher ending with the app; and, with a stand-in WIA whose enumerations end when told, parked on the demo: a scanner Windows Scan lists first is not chosen, WIA is asked to look again at once and is used when it lists the scanner (Windows Scan never opened), a WIA look that began before the scanner appeared does not count, and Windows Scan is chosen once WIA has looked and does not list it. `WiaEnumerationTests` checks that a refresh asked for while WIA enumerates starts one more after it, and `WinRtScannerTests` that the sources a session reads raise a list change, which writes `devices.txt` again. **Unverified:** real devices: listing, names and grouping with their WIA entries, capabilities, scans, preview, the feeder, two sides and their page order, paper sizes, cancel, and the file names a partly scanned batch leaves |
| Task start screen (`TaskCatalog`, `TaskFlow`, `SettingsAdapter`) | Covered by `ScanTaskTests`, `TaskFlowTests`, `SettingsAdapterTests` and the task cases in `ModelsCompatTests` (same cases as macOS). Checked by driving the view model with the demo scanner and fake flatbed-only and feeder-only scanners (each task's settings, scans and file names, the task ending when the mode is changed by hand or the scanner lacks its source, the reasons on unavailable cards, presets and scanner switches going through `SettingsAdapter`, the task coming back after a restart), and by building the window without showing it: tabs, cards, banner, keyboard navigation, screen-reader names and the banner's announcements of the task and of each new step, rendered off screen in light and dark |
| PDF sizes (`PdfImageEncoding`, `ColorAnalysis`) | Covered by `PdfImageEncodingTests`, `ColorAnalysisTests`, the gray-JPEG cases in `PdfBuilderTests` and the size cases in `ModelsCompatTests` and `ScanTaskTests` (same cases as macOS). Checked by driving the view model's real save path with two public-domain document scans in every color mode and size (image size and color space as planned, page size unchanged, every PDF renders through Windows.Data.Pdf close to the scan, sizes shrink in order; see [PDF size](#pdf-size)) and by building the window without showing it: the size control, its hint and last-size line, hiding it for other formats and Photos, the Email card, rendered off screen in light and dark |
| Black & white as CCITT G4 (`CcittG4Encoder`, `Bilevel`, `BilevelTiff`, `PdfCcittImage`) | Covered by `CcittG4EncoderTests` (the code tables against T.4, known answers for all-white and all-black pages, pass, horizontal and every vertical mode, runs past 2560, no rows, single pixels and one-pixel lines; every run length of both colors, odd widths and 20000-pixel rows decoded back by PdfPig's CCITT filter; golden bytes for a checkerboard, seeded noise and the blank-page tests' text page; the threshold), `BilevelOutputTests` in Core (the image dictionary and its data, JPEG and G4 pages with a text layer, PDF/A, a protected file opened with its password, a page added to a PDF, all decoded by PdfPig; one- and three-page TIFFs field by field, golden bytes) and in the App tests (WIC decodes one- and three-page TIFFs pixel for pixel; WIC's own G4 encoder gives the same bytes, strip by strip, for every page and every run length; saving a black & white TIFF writes G4 and others stay LZW; turning one in the Saved tab keeps it G4; Windows.Data.Pdf renders plain, PDF/A and added G4 pages pixel for pixel, read at three times their size), and the G4 cases of `PdfImageEncodingTests` (same cases as macOS). Checked by driving the view model's real save path with the two public-domain scans in black & white at every size, at 300 and 600 dpi, as PDF/A, with a password, added to an existing PDF and as TIFF: the image is the planned 1-bit G4 image, PdfPig decodes exactly the stored pixels, Windows.Data.Pdf renders it as it renders the same pixels in a quality-100 gray JPEG (it resamples large page images whatever their encoding), WIC decodes the TIFFs exactly; sizes in [PDF size](#pdf-size). **Not run:** veraPDF on a black & white PDF/A file here (CI validates the new `pdfa-black-and-white.pdf` sample) and qpdf (neither is installed here). **The Mac** writes the same G4 bytes through its port (`CCITTG4Encoder`, `Bilevel`, `BilevelTIFF`; their Swift tests, `CCITTG4EncoderTests` and `BilevelOutputTests`, check the same golden values, and `PDFWriterTests.test_g4AndJpegPages_goldenBytes` is the Swift twin of `BilevelOutputTests.Pdf_G4AndJpegPages_GoldenBytes`, a plain PDF with a G4 page and a JPEG page) in its PDFs with black & white pages and its black & white TIFFs; compiled and run by macOS CI, not here |
| One row per scanner (`DeviceMerge`, connection chooser) | Matching rules, ranking and the saved choice are covered by `DeviceMergeTests` (same table as macOS) and were checked by driving the view model with fake WIA and TWAIN backends: one row, WIA preferred, a later-appearing better connection taken over once the running scan ends, the user's choice saved and used at the next start, a choice made during a scan applied after it. A saved choice is keyed by the eSCL UUID or the model name, whichever the current set of connections yields, so it lapses when that set changes (see above). **Unverified with real drivers:** the names real WIA, eSCL and TWAIN drivers report; `devices.txt` collects them |
| TWAIN backend (`Scanning/Twain`) | **Experimental, untested against hardware** — see [TWAIN](#twain) below. The scan logic in Core (negotiation choices, the acquisition state machine, strip and bitmap conversion, paper sizes, error mapping, 32-bit driver detection) is covered by `TwainScanLoopTests`, `TwainRasterTests` and `TwainScanRequestsTests` through a fake transport. Driving the view model with the real session class over a scripted transport checked flatbed, feeder, preview, empty feeder, a jam after two sheets (pages kept, reason shown), cancel while the driver is silent (returns at once, the source is reset and disabled in the background), switching away (the source is closed without waiting), the driver-window switch and its saved choice (kept when connecting finds the scanner off), a driver stuck while enabling (reported after the start limit, the next scan refused at once, the late scan stopped when the driver answers), and that a scanner only TWAIN lists is never opened unless the user picks it. On a PC without a TWAIN Data Source Manager the backend lists nothing and `devices.txt` says why; the app starts normally. **Unverified:** real drivers, NTwain's message loop with them, the TWAIN Working Group sample source (not installed here) |
| 32-bit TWAIN helper (`LazyScan.TwainHelper`, `Scanning/Twain/Twain32ScannerBackend.cs`, `TwainHelperProcess.cs`) | **Experimental, untested against hardware.** The protocol is covered by `TwainHelperProtocolTests` (every message both ways, resolution lists of every shape up to the widest range a driver can report, malformed and random input, errors) and `TwainHelperSessionTests` (the app's end against the helper's end over an in-memory pipe with the scan loop on top: scans with chunked strips and bitmaps, scanner problems, cancel, a crash, a hang, a 50 to 9600 dpi range in 1 dpi steps). `TwainHelperTests` start the real x86 helper with its stand-in scanners: listing (the WIA bridge left out), a feeder scan and a preview end to end, a native transfer with progress, a jam, an offline and a busy scanner, cancel, a crash and a hang (each reported, the next scan starting a new helper), the helper exiting by itself when the pipe closes, the pipe's access list, a missing helper (reported with its fix, not tried again on its own), a failed listing and a helper too slow to start (both tried again), a Data Source Manager that lists only the WIA bridge (the 32-bit drivers stay a troubleshooter problem, with why) and a PC without 32-bit-only drivers (no helper started). Driving the view model with the helper and a stand-in WIA connection to the same scanner checked one row with both connections (WIA preferred, "TWAIN (32-bit driver)" in the chooser), TWAIN-only rows captioned "TWAIN (32-bit driver)" and never picked on their own, a feeder scan of 3 pages through the helper, `devices.txt` and the helper ending with the app; killing the app's process ended the helper within a fraction of a second. **Unverified:** real 32-bit drivers and Data Source Managers (this PC has none), driver windows shown by the helper process |
| Two-sided scanning and paper size (`DocumentSides`, `PaperSize`) | Covered by `DocumentSidesTests`, `PaperSizeTests` and the sides cases of `ModelsCompatTests`, `ScanTaskTests`, `SettingsAdapterTests` and `MockScannerTests` (same cases as macOS), plus the backend requests in `EsclTests`, `TwainScanRequestsTests` and `WiaErrorsTests`. Checked by driving the view model with the demo scanner (both sides in one pass on the long and the short edge, a jam keeping one sheet's two sides, turning over by hand with matching counts, a mismatch, scanning the backs again, combining anyway, keeping the fronts, a jam during the fronts (the steps stay at the fronts, the rest of them scanned as fronts, Done with fronts), a stack scanned in parts (Scan more fronts), a scanner whose capabilities could not be read on connect asked for both sides by a one-sided feeder (pages kept one-sided, capabilities read after the scan), earlier pages keeping their place, the two-sided task on two-sided and one-sided feeders, paper sizes on the feeder and the glass, the saved PDFs' page counts) and by building the window without showing it: the Sides, Flip on and Paper size choices with their greyed-out items and reasons, the banner's two steps, Scan more fronts, Done with fronts and the mismatch choices, the side badges and the screen reader names in the page strip and the Two-sided document card, rendered off screen in light and dark. **Unverified:** real drivers (see [Two-sided scanning and paper size](#two-sided-scanning-and-paper-size)) |
| Crop and straighten (`DocumentGeometry`, `GeometryStep`, `PageCorrections`) | Covered by `DocumentGeometryTests`, the crop and straighten cases of `PageProcessorTests`, `ModelsCompatTests`, `ScanTaskTests` and `MaskOpsTests` (same cases as macOS, on the same synthetic pages checked by checksum). Checked on public-domain scans laid at known angles on a lid and a dark backdrop, on archive scans as they were captured, and by driving the view model with those scans (scan, the strip's captions, both versions spooled, show as scanned and back, turning a page, saving whichever version is shown, removing and clearing pages, the switches off and pages saved at once, the two-sided task) and by building the window without showing it: the switches and their hint, the swap button and its glyphs, rendered off screen. **Unverified:** real lids, feeder backings and thin paper (see [Crop and straighten](#crop-and-straighten)) |
| Camera clean-up and the automatic shutter's checks (`DocumentEnhancer`, `EnhanceStep`, `FrameQuality`, `CaptureStability.Judge`) | Covered by `DocumentEnhancerTests` (synthetic shadowed pages: the paper one white within 5 levels from a shadow down to 37 % light, the print kept black, the paper's tint taken out, a dark picture kept dark, a hard-edged shadow at 45 % from the page's edge evened out with its print kept, light print on a dark ground kept, black and white bilevel, golden bytes for every mode recomputed by an independent model), `FrameQualityTests` (pinned readings, a scripted blurred, dark and sharp sequence taken once) and the new `CaptureStabilityTests` and `CapturePageTests` cases, the same cases as macOS. No Windows screen uses them yet; real phone photos are to be checked on the iPhone. |
| Camera geometry (`PerspectiveWarp`, `CaptureScale`, `MultiQuadPicker`, `PerspectiveStep`, `ScannedPage.Capture`) | Covered by `PerspectiveWarpTests` (golden bytes recomputed by an independent model of the algorithm, the round trip within 1 px and 30 dB), `CaptureScaleTests`, `MultiQuadPickerTests`, `CapturePageTests` (with the facts turned, mirrored and resized with their photo for all eight orientation tags, and a photo turned without its facts left alone) and the capture cases of `CompanionPackageTests` (same cases as macOS), and the phone page's facts by `CompanionAppTests`. No Windows screen uses them yet; the iPhone app imports photos with them (I7) and brings in its own camera's photos the same way (I8; auto-shutter in I9) |
| Several objects in one shot and glare (`CaptureObjects`, `GlareDetector`, `PhotoReview`, `PageProcessor.ForCapture` for objects) | Covered by `CaptureObjectsTests` (two prints cut out at 4 × 6 in, an ID card shot turned 25° and tilted 35° composed on A4 at 85.60 × 53.98 mm within 0.5 mm, thermal receipts on a white table and prints on a plain table found in the whole shot, no text recognition on photos, receipts or the ID card) and `GlareDetectorTests` (readings pinned to an independent model), the same cases as macOS. No Windows screen uses them; the iPhone app does (I13). Real glare, holograms and thermal receipts need a real iPhone |
| The camera's two-sided pages and book spreads (`ScanArrangement.CameraFront` / `CameraBack`, `DocumentSides.MarkCamera`, `PageProcessor.Prepare`, `SplitsCameraSpreads`, `TaskOptions.CameraFrontsFirst` / `CameraSpreads`) | Covered by `DocumentSidesTests`, `PageProcessorTests`, `CapturePageTests` (a drawn spread photographed on a table, cut out at its own pixels and split near its spine in either reading order, spreads shaped like an ID card or A4 not snapped to them, a gray spread's pages kept gray), `BarcodeTests` (photographed Patch T and QR separator sheets) and `ModelsCompatTests`, the same cases as macOS. The Windows app never produces them; the iPhone app does (I14). A printed sheet photographed and a real book need a real iPhone |
| Photos of documents (`PhotoDocumentDetector`, `PerspectiveCorrector`, `PhotoImport`, `PhotoFileReader`, `PhotoCornersWindow`) | The rules (orientation tags, when to ask, the resolution, the corner editor's limits, the page and its photo, the words) are covered by `PhotoImportTests` (same cases as macOS) and the detector and corrector by `PhotoDocumentDetectorTests`, `PerspectiveCorrectorTests` and `HomographyTests`; reading with WIC by `PhotoFileReaderTests`. The import, the drop, the corner editor (light and dark, rendered off screen) and the saved PDF were checked through the view model on composited photos (see [Photos of documents](#photos-of-documents)); real phone photos are still to check |
| Rotate pages upright (`OrientationDecision`, `OrientationStep`, `PageTurns`, `WindowsOrientationScorer`) | Covered by `OrientationTests` and the rotate cases of `PageProcessorTests`, `ModelsCompatTests` and `ScanTaskTests` (same cases as macOS, on the same synthetic page read by a stand-in scorer). Checked with Windows OCR on public-domain letters and menus turned every way and on photos (see [Rotate pages upright](#rotate-pages-upright)), by driving the view model with those scans (scan, the strip's captions, the spool files and what a save writes, undo and redo, two quick clicks, a turn by hand before and after, Keep and Skip, saving, the switch off, pages saved at once, no OCR language, the two-sided task) and by building the window without showing it: the switch and its hint, the turn button beside the side badge and the swap button, screen-reader names, rendered off screen in light and dark. **Unverified:** Vision on the Mac (CI runs the stand-in only), real feeders |
| ID card (`IdCard`, the review) | Covered by `IdCardTests` (paper, steps, layout on Letter and A4, scaled to fit, the composed page in pixels and as a 612 × 792 pt PDF page, the detector on a synthetic bed with a card turned 7° among other objects, the back taking the front's place, moved to another resolution and refused for another part of the glass, the page at most 600 dpi, Skip only for the card's back) and the ID card cases of `ScanTaskTests`, `ModelsCompatTests`, `TaskFlowTests` and `MockScannerTests` (same cases as macOS). Checked by driving the view model with the demo scanner's sample card (front, back, the review, turning and swapping the sides, fixing a crop, Letter and A4, saving a PDF at 612 × 792 pt with no text layer, a PNG page at 300 dpi with the front as an image, skipping the back, scanning a side again, discarding, leaving the task, picking a task again) and with a white-on-white back (at the front's resolution, at twice it, and with another selection), a scanner going away with the review open and between the sides (no switch until the card is saved, discarded or the task left), a page saved from a 1200 dpi scan (A4 at 600 dpi, the side at 1200), the stage cleared on leaving with no side held, checking that nothing goes to the history or the page spool and that the stage is cleared, and by building the window without showing it: the task card, the banner's steps and Skip back side (and no Skip for the backs of a stack turned over by hand), Mode and Source locked while a side is held, Leave the task and picking a task asking first (Cancel keeps the card, Discard drops it), the review with both sides, the front only, the not-at-real-size warning, the paper and format pickers, rendered off screen in light and dark. **Unverified:** real cards on real lids (see [ID card](#id-card)), printing at real size |
| Blank pages (`BlankPageDetector`, `PageProcessor`, `PageFilter`, image toolkit) | Covered by `BlankPageDetectorTests`, `PageProcessorTests`, `GrayImageTests`, `RgbaImageTests`, `MaskOpsTests` and the blank-page cases of `ModelsCompatTests`, `ScanTaskTests` and `MockScannerTests` (same cases as macOS; `MaskOpsTests` also pins PhotoDetector's regions on the demo bed to the last bit, unchanged by moving the mask code out of it). Checked on public-domain scans of letters, menus and photos (none taken for blank, at any level, with or without their dark surroundings) and on blank backs made from them (all found blank), and by driving the view model with the demo scanner (flagging, Skip blank pages turned on and off with pages queued, Keep and Skip per page, rotating a flagged page, saving 5 of 6 pages, nothing to save, pages saved at once keeping every page, the two-sided task, turning over by hand) and by building the window without showing it: the switch, the levels, the badges, Keep and Skip, the strip label, Save PDF's count, rendered off screen in light and dark. **Unverified:** blank backs from real scanners (see [Blank pages](#blank-pages)) |
| Copy and print (`PrintLayout`, `PrintService`, the Copies section) | The layout is covered by `PrintLayoutTests` (real size on A4 and Letter, a whole glass cut off on A4, printer margins, a selection centred, turning only when that cuts off less, fit with and without turning, never enlarged, units, printer paper, copies, the ruler page by pixel, the texts) and the copy cases of `ScanTaskTests`, `ModelsCompatTests`, `PaperSizeTests` and `IdCardTests` (same cases as macOS); the print document by `LazyScan.App.Tests` (written to XPS and read back: the page is the paper, each image at its place in 1/96 in, turned pages turned in their pixels, fitted pages placed smaller, copies the printer does not make repeated, every page its own picture, grey images, cancel). Checked by reading the real print system on Windows 11 without printing (the printers, the default printer's Letter paper and printable area, A4 and Letter asked of Microsoft Print to PDF, an unknown printer; the default printer and its ticket compared before and after: unchanged), by driving the view model with the demo scanner and a stand-in printer service that records the jobs (a copy from the corner at real size, the printer's paper area of the glass scanned, A4 asked and scanned, a selection centred, 3 copies on a printer that makes 2 at most, fit to page, grey, also a PDF, the feeder's stack, another printer, a printer gone, a refused job and Cancel while printing, no printer; the ID card printed on Letter at real size with the review kept, A4 on a Letter-only printer, margins reaching the card; Automatic paper following the default printer; the ruler page), with every recorded job's document written to XPS by the app's own code and its geometry read back, and by building the window without showing it: the Copy card, the Copies section and its controls, no printer, the review's Print button, rendered off screen in light and dark. **Not done:** printing to a real printer, including Microsoft Print to PDF (its file name cannot be set without its save dialog). **Unverified:** real printer margins and offsets, measured with the ruler page |
| Text output (`OcrText`, `TextExport`, `DocxWriter`, `ZipStore`, Copy Text) | Covered by `OcrTextTests`, `TextExportTests` (with `OutputFormatsTests`), `DocxWriterTests` (with `ZipStoreTests`: CRC-32 known values, exact zip bytes, the package opened with `ZipArchive`, its parts, content types and relationship checked) and the text cases of `ModelsCompatTests`, `ScanTaskTests` and `SaveActionsTests` (same cases as macOS; both platforms pin the same CRC-32 of the sample text file and Word document). Checked by driving the view model with the demo scanner, the public-domain letter scan and Windows OCR (a PDF and its text file with one OCR pass per page, no OCR when neither is asked for, a taken name kept, Scan to Word with the letter, Text and Word saved at once, Copy Text into a stand-in clipboard, a blank page, a PC without an OCR language), and by building the window without showing it: the format lists for documents and photos, Also save text, the Save Word button, the Scan to Word card, the page menu's Copy text, rendered off screen in light and dark. **Not tried:** opening the documents in Word or LibreOffice (neither is installed here), and the real clipboard |
| Page pictures in Word documents (`DocxWriter` pictures, `WpfImageCodec.EncodeDocxPicture`, Include page images) | Covered by `DocxWriterPictureTests` (same cases as macOS: the parts, relationships and content types read with `ZipArchive`, the exact markup of a picture paragraph, the sizes in EMU, numbering, the text-only package unchanged, the JPEG and PNG fixtures read back, the PNG decoded without any library; both platforms pin the same CRC-32 and length of the package with pictures; `PackageSize` is the length written, and a document past the 2 GB limit is told without writing it), the page pictures cases of `ModelsCompatTests` and `ScanTaskTests`, and `LazyScan.App.Tests/DocxPictureTests` (WIC decodes the pictures the app encodes: color and gray JPEGs at each size's resolution, the 1-bit PNG of a black & white page pixel for pixel, a whole document's pictures through its relationships). Checked by driving the view model off screen with the real letter (color) and menu (black & white) scans and Windows OCR: Scan to Word with pictures on by default, OCR once per page, a color JPEG at 300 dpi and a 1-bit PNG holding exactly the page's pixels, each page's picture then its text, 955 KB against 934 KB for the same pages as a Standard PDF; the letter at 600 dpi as Best 2.87 MB, Standard 853 KB, Compact 257 KB, Smallest 120 KB; pictures off giving the text-only document byte for byte and kept when the task is picked again; a scan saved at once with its gray picture; and the inspector built without showing the window (the switch, its hint, "Page image size" without the PDF-only switches, rendered light and dark). **Not tried:** opening the documents in Word, LibreOffice, Pages or Google Docs |
| Password-protected PDFs (`PdfEncryption`, `PdfProtection`, `PdfPasswordWindow`) | Covered by `PdfEncryptionTests` (algorithm 2.B, /UE and /OE known answers from pdf.js's PDF 2.0 cases; SASLprep; /Perms; the values for fixed random bytes, also computed by a separate implementation; AES-256-CBC with its IV and padding; the /Encrypt dictionary; the file's numbering, catalog and trailer; streams and strings decrypting back; PdfPig opening the file with the password only; permissions; one key per file; PDF/A refused; golden bytes; the password strength and problems) and the password cases of `ModelsCompatTests`, `ScanTaskTests` and `SaveActionsTests` (the same cases as macOS: `PDFEncryptionTests` has the writer's, with the same values and golden file, and opens the files with PDFKit). Checked by driving the view model with the demo scanner and a stand-in for the dialog (asked once per save, a split stack of three with one password and three keys, Cancel and no one to ask saving nothing, saving as scanned keeping the page, the Archive document task turning it off, no password in settings, presets, `devices.txt` or the spool), every saved file opened by PdfPig with the password and refused without it, and by building the window and the dialog without showing them: the switch, the two switches greying each other out with the note, the dialog's strength hint, mismatch message, permissions and Save, rendered off screen in light and dark. **Not opened by `Windows.Data.Pdf`:** it opens no revision 6 file (reference files made by qpdf fail the same way). **Not run:** qpdf (not installed here) |
| Add pages to an existing PDF (`PdfReaderLite`, `PdfAppender`, the button and the Saved tab's menu) | Covered by `PdfReaderLiteTests` and `PdfAppenderTests` (same cases as macOS: `PDFSyntaxTests`, `PDFReaderLiteTests` and `PDFAppenderTests`): the syntax, Flate and its predictors, classic tables, cross-reference streams, object streams, files already updated, hybrid files, nested and indirect page trees, inherited attributes, generations, names and strings written back, the update's bytes, PDF/A kept or asked about, signed and certified files, and every refusal (encrypted, damaged, objects read when asked for, a page as the tree's root, object numbers past the limit, unsupported, read-only, a folder that takes no new files, open elsewhere, missing, cancelled) leaving the file as it was with a message for the user; the replaced file keeping its permissions and its Zone.Identifier stream; every result read by PdfPig with lenient parsing off. Checked on files made by Skia, Figma and Microsoft Word (hybrid, object streams) and pdf.js's encrypted test files, read back by PdfPig and rendered by `Windows.Data.Pdf`, and by driving the view model and the window off screen with the demo scanner. veraPDF runs in CI on a PDF/A file with pages added. **Not run here:** qpdf (not installed) |
| Archival PDF and the Unicode text layer (`PdfObjectWriter`, `GlyphlessFont`, `GlyphlessCodes`, `PdfA`) | Covered by `PdfATests`, `GlyphlessFontTests`, the text-layer cases of `PdfBuilderTests` and the archival cases of `ModelsCompatTests`, `ScanTaskTests` and `SaveActionsTests` (the same cases as macOS: the object writer, the font, the plain and the PDF/A file have Swift twins with the same cases and golden bytes, `PDFWriterTests`, `GlyphlessFontTests` and `PDFATests`): object numbering, the catalog, output intent, Info and XMP that agree, the trailer's identifier, no encryption, golden bytes, the font's tables and checksums, the CIDToGIDMap inflated, and the text layer read back through PdfPig in Turkish, Greek, Cyrillic, Arabic, Hebrew, Japanese, Chinese, Devanagari and beyond the BMP. Checked by driving the view model with the demo scanner and a stand-in OCR (the Archive document task's PDF/A file, the switch on the Document task, a plain PDF with the Unicode text layer; every file opened by `Windows.Data.Pdf`), with DirectWrite reading the font, and by building the window without showing it: the Archive document card, the switch and its hint, the task ending when it is turned off, rendered off screen in light and dark. veraPDF runs in CI on the PDF/A files a test writes. **Not run here:** veraPDF and qpdf (not installed) |
| Share, email, open with, copy (`SaveActions`, `FileActions`, `ShareService`) | The choices are covered by `SaveActionsTests` and the after-save cases of `ModelsCompatTests` (same cases as macOS). Checked by driving the view model's real save paths with a stand-in for Windows (each after-save action after a PDF, a file saved at once and a photo batch; the Email task sharing; no share window; a refused action; a moved file; a cancelled save running nothing), by building the real clipboard data and share package without placing them anywhere, and by building the window without showing it: the bar, its buttons and menu, the narrow layout, the "After saving" choices, the Saved tab's buttons and menus, rendered off screen in light and dark. **Not tried on screen:** the share window, the Open with dialog and the clipboard themselves (checks must not send, open or overwrite anything), and Mail or Outlook as share targets |
| Troubleshooter (`Troubleshooter`, `SystemDiagnostics`, `TroubleshooterWindow`) | The checks are covered by `TroubleshooterTests` (same cases as macOS) and the Windows service and network values by `WindowsSystemStatusTests`. Checked by driving the view model with stand-in connections and a stand-in for Windows (the snapshot, the order of the checks, devices.txt, Refresh, Copy diagnostics and Settings refused, a busy scanner at connect and at scan, a connection that works clearing it, a cancelled scan not counting), by reading the real WIA service and network on Windows 11 (Running and Public, as `sc query` and `Get-NetConnectionProfile` report, from UI and thread-pool threads), by copying to the real clipboard with the user's clipboard saved and restored, by an address added by hand on loopback where nothing listens, by a discovered scanner (a stand-in service for a loopback scanner) that stays listed, selected and connected across a Refresh when Windows aborts either network watcher, and dropped only once the restarted watcher's first pass did not find it again, and by building the sidebar, error bar and troubleshooter window without showing them: the header button, the empty state's links, the error bar's Troubleshoot (and none on a file or photo error shown later), one card per check with its buttons and screen-reader names (each card a named group in the UI Automation tree), a Refresh while one runs ignored, rendered off screen in light and dark. **Not tried on screen:** opening Windows Settings and the real Add scanner dialog from it. **Unverified:** a stopped or disabled WIA service, a TWAIN install with 32-bit-only drivers, and a scanner that is really busy in another app |
| Receipts (`ReceiptDetector`, `ReceiptEnhancer`, `ReceiptDateExtractor`, the review) | Covered by `ReceiptTests` (two receipts on a white lid found apart along their paper, cut around their print when the paper is as light as the lid, a 2 × 11 in receipt that is too long for a page but not for a receipt, prices far from the items, two receipts 0.15 in apart, one receipt per feeder sheet, nothing on the glass, a 300 dpi scan, the enhancer on fading paper, little print and a dark logo, the date rules and the 99-case date set, the texts) and the receipt cases of `ScanTaskTests`, `ModelsCompatTests`, `NamingTemplateTests` and `MockScannerTests` (same cases as macOS, on the same synthetic beds checked by checksum). Checked on harder synthetic beds (four receipts on a white lid, an open lid and with invisible paper, 12° tilts, receipts in a column 0.2 in apart, a receipt lying sideways, an 11 in receipt at the glass's edge: all found and held whole; two receipts 0.15 in apart with paper as light as the lid are not told apart), by driving the view model with the demo scanner and Windows OCR (both receipts found and cut along their paper, a gray Compact PDF each with a text layer named by its own date, one PDF for all named by the earliest, JPEG files, the text beside each PDF, today's date without OCR, OCR that fails, a save cancelled while reading, Fix crop, Discard) and by building the window without showing it: the Receipts card, the inspector's Receipts section and its switches, one PDF off for JPEG, the review's title and save button, rendered off screen in light and dark. **Unverified:** real thermal receipts on a real lid (see [Receipts](#receipts)) |
| Separate documents (`PatchCodeDetector`, `DocumentSplitter`, `SavePlan`, the strip's gaps) | Covered by `PatchCodeTests` (all six codes across and down the page, ±2.5° and ±3°, the separator sheet at 100 and 300 dpi and turned, its bar widths, no code on text, a ruled table, blank pages, photos), `DocumentSplitterTests` (every mode, the two-sided blank-sheet rule, separators in a row, empty documents, every N sheets with an odd last sheet and skipped sheets, splits and joins by hand and their undo, keeping a separator page, names, also across a change of the settings, the strip's texts) and `SavePlanTests` (the documents, the texts, all or nothing on success, failure and cancel), and the split cases of `ModelsCompatTests`, `ScanTaskTests`, `PageProcessorTests`, `NamingTemplateTests` and `MockScannerTests` (same cases as macOS). Checked by driving the view model with the demo scanner's batch stack and stand-ins for OCR, the file actions and the printers (the task's settings and card, three PDFs of 2, 1 and 2 pages named with their number, the separators left out, the queue and its spool files cleared; joining, splitting and undoing by hand, keeping a separator page, naming a document from any of its pages, turning and moving pages; a save whose third file cannot be written and one cancelled during the second document leaving no file and the queue intact, then saved again with the text beside each PDF; three text files; both sides with blank backs skipped and separator backs left out; at blank sheets; every 2 sheets; no split ending the task; the separator sheet printed on Letter and A4 stand-in printers (and on the printer's paper when the scan asks for Legal), read back as Patch T, and refused without a printer, then saved as a PDF without one, a page of the usual paper read back as Patch T, and saved again under the next free name; a named first page skipped and kept again with the name following it, and left out and saved again by a change of what counts as blank, of Skip blank pages and of the split, a 300-character name cut to 100; the PDFs' size, the text files beside them and "no text was found" in the status; the last PDF size put back after a failed or cancelled save; another task unchanged) and by building the window without showing it: the card, the Split into documents choice and its hint, Print separator sheet, Sheets per document, the strip's badges, gaps and bars, a click on a gap joining two documents, the save button and label, the name box's 100-character limit, Save separator sheet (PDF) and its hint, Skip blank pages greyed out with the reason at blank sheets one-sided and back with both sides, the choice greyed out when each scan is saved at once, rendered off screen in light and dark. **Not tried on screen:** the name box (a popup window) and the page menu. **Unverified:** printed separator sheets scanned by real feeders (see [Batch of separate documents](#batch-of-separate-documents)) |
| Barcode and QR separator sheets (`Barcodes.cs`, `BarcodeStep`, `ZXingBarcodeReader`, `ZXingQrEncoder`) | Covered by `BarcodeTests` (the four kinds, reading order and repeats, bounds back in the page's and a spooled page's pixels, a queued page read on its spool file turned like the page and left unread when only its preview shows nothing, the separator prefix and the codes it ignores, the name a code's text gives with format characters dropped, the step and when it runs, every rule of the split at barcode or QR sheets one- and two-sided, keeping, names typed winning, the strip's texts naming the document the plan starts, the QR sheet and the demo's Code 39 sheet pinned by checksum; same cases as macOS), `OrientationTests` (barcode or QR separator sheets not turned upright) and the barcode cases of `ModelsCompatTests` and `MockScannerTests`, and in the app's tests by `BarcodeReaderTests` (ZXing.Net on synthetic scans at 150, 200 and 300 dpi with noise and a ±3° slant: every kind, Data Matrix anywhere, several codes, no false codes, QR sheets in four scripts, a queued page's preview, small 1D codes a preview loses read from the spool file, an end-to-end stack with an order number ignored). Checked by driving the view model with the demo scanner's stack of Code 39 sheets (split and named, saved as "Document INVOICE 1002 … 2.pdf"; queued pages read when the split is chosen later, from their previews; a barcode starting a document; a typed name winning and removed; a separator page kept) and stand-in printers (the QR sheet saved as a PDF and printed on Letter and A4, each read back exactly, a Turkish name included; Patch T with the switch on), and by building the window without showing it: the choice, the switch and its hint, the name box, the QR buttons, the strip, rendered off screen in light and dark. **Unverified:** printed QR sheets fed through real scanners, codes printed by other software, Vision on a Mac (CI runs `VisionBarcodeTests`) |
| Send from your phone (`Companion/`, `Services/Companion/`, `PhoneWindow`) | The protocol pieces are covered by `SpkiFingerprintTests`, `PairingUriTests`, `PairingSessionTests`, `PairedDeviceStoreTests`, `CompanionHttpTests`, `CompanionProtocolTests` (same cases as macOS), the server by `CompanionRouterTests`, `CompanionNetworkTests` and `CompanionLoopbackTests` (a fake phone over TLS on 127.0.0.1: pairing with the pinned certificate, a wrong fingerprint refused, expired and reused codes refused, a removed phone gets 401, idempotent uploads, damaged, malicious, oversize and chunked uploads refused, rate limits, listening stops when the network is no longer trusted and starts again when it is allowed, advertising only on trusted interfaces, a phone waiting for the user's answer keeps the PC listening and a declined one stops it, no pairing session left open when no code can be shown, a reset without a new key changing nothing), the app's side by `CompanionAppTests`, and a window-free run of the view model and the Phone window with a fake phone (the question, staying while the window's clock ticks and the PC is refreshed, queued pages labelled From phone, a retry not added twice, a document waiting in Photos mode, a document kept when its pages cannot be spooled, the firewall verdict for the network received on only, a failed reset reported, a launch with an unreadable inbox still serving the paired phone). **Needs the user's PC and a phone:** Windows Firewall's question when the app first listens (on a Public network approved in the app: tick Public networks), a cancelled question (block rules, shown by the checks), the certificate in `CurrentUser\My` (checked on CI in a store of the test's own), DNS-SD with `DnsServiceRegister` (never run here), and the iPhone app itself (I20). |
| eSCL backend (`EsclScannerBackend`) | **Experimental, untested against hardware** — see [Network scanners](#network-scanners-escl) below for discovery, adding by address and HTTPS. Feeder-only devices offer no flatbed or preview; feeder jobs ask for the paper size's region, clamped to the feeder (the feeder's own sheet size for Automatic, at most 17 in tall); two-sided feeder jobs send `<scan:Duplex>true</scan:Duplex>` and use the two-sided feeder's capabilities (`AdfDuplexInputCaps`) when the device lists them, and a device that lists no two-sided feeding scans one side and says so; black & white is requested as grayscale and thresholded by the app, because most devices reject 1-bit JPEG; busy (HTTP 503) answers are retried for up to 60 s; relative job addresses are resolved; when a job fails, the scanner's status explains it (empty feeder, jam, cover open, …); a feeder job that fails partway (an error answer, a dropped or stalled connection, a page that cannot be read) keeps the pages already received and tells the user how many were kept and why it stopped; a job that is cancelled or cut short is deleted on the device. The protocol client (`EsclClient`, `EsclScannerSession`) is covered by `EsclClientTests` through a stub HTTP handler (the same cases as the iPhone's Swift twin). Checked against local fake eSCL servers (plain and HTTPS), not a real device |

Known divergences from the macOS app (all documented in the source):

- `ImagePipeline` re-implements the Core Image filters as per-pixel math — visually close,
  not bit-identical; auto-enhance is a histogram auto-level rather than Apple's suggestion
  list.
- The demo scanner's document page draws text-shaped bars, not real glyphs (Core has no
  font rasterizer), so OCR demos need a real scan. Its receipts are the exception: they are
  printed in a plain stroke type drawn pixel by pixel (the same on the Mac), which Windows OCR
  reads.
- WIA, Windows Scan and TWAIN exist only here, so their logic in Core (`WiaErrors.cs`,
  `WindowsScan.cs` and `ResolutionList.FromBounds`, `Twain/`) and its tests
  (`WiaErrorsTests`, `WindowsScanTests` and the `FromBounds` cases of `ResolutionListTests`,
  `TwainScanLoopTests`, `TwainRasterTests`, `TwainScanRequestsTests`, `TwainHelperProtocolTests`,
  `TwainHelperSessionTests`, and `WinRtScannerTests` and `WiaEnumerationTests` in
  `LazyScan.App.Tests`) have no Swift counterparts, nor has the 32-bit TWAIN helper: the Mac reaches
  the same scanners through ImageCaptureCore, whose Bonjour browsing also finds network
  scanners. The scanner problems they report (`ScannerProblem`) are shared with macOS. The eSCL
  protocol (`Escl/`) is shared since the iPhone needs it: its Swift twins pass the same cases
  (`EsclTests`, `EsclRetryTests`, `EsclDiscoveryTests`, `EsclTrustTests`, reading the same
  fixtures in `Tests/Fixtures/Escl`), and so do the HTTP client and session since the iPhone's
  eSCL connection (I11): `EsclClientTests` are the same 18 cases there on a `URLProtocol` stub,
  and the two `EsclTrustTests` cases that go through a real TLS connection have their twins in
  `EsclLoopbackTests` (a loopback `NWListener` serving the fixtures' two test identities). The
  scanner problems include one Windows never produces, `AppSuspended` (the iPhone suspended the
  app in the middle of a network scan; the pages received are kept); its text is shared. The
  search for scanners and the backend around it are each platform's own: Windows has its device
  watcher (`EsclDiscovery.cs`) and `Scanning/EsclScannerBackend.cs`, the iPhone an NWBrowser per
  service type with DNS-SD resolving and a Swift `EsclScannerBackend` with the same device list,
  addresses added by hand and troubleshooter view (their Swift tests have no C# twin); what they
  hand over (`EsclService`, `EsclEndpoint.Choose`, `EsclHostList`) is shared.
- The iPhone's troubleshooter cases are in Core with their Swift twins and the same tests
  (`TroubleshooterTests`), though Windows never produces them: `TroubleshootPlatform.Ios`,
  `DiscoveryStatus.Denied` (the iPhone's Local Network access is off: the "localNetwork" problem
  with `TroubleshootAction.OpenAppSettings`, "Open Settings") and the iPhone's own network check and
  tips. So is `DeviceMerge.IosRanking` (`["escl:Network", "companion:*"]`, `DeviceMergeTests`),
  which the Windows app never uses.
- The troubleshooter's checks (`Troubleshooter`) are shared, but each app fills in what it can
  read. Windows reads the WIA service, the network category, TWAIN (with why its 32-bit helper
  does not reach a driver, `ThirtyTwoBitHelperProblem`) and the addresses added by
  hand (`WindowsSystemStatus.cs` and its `WindowsSystemStatusTests` have no Swift twin); the Mac
  reads only whether ImageCaptureCore is browsing, since macOS offers no API for its scanner
  drivers, sharing or the Local Network permission, so those are tips there. The Mac links to
  Image Capture and to Printers & Scanners instead of adding a scanner by address, which macOS
  cannot do.
- Only Windows offers a connection chooser: the Mac merges its USB, Bonjour and shared
  entries for one scanner by ranking alone (USB first) and has no preferences file to keep a
  choice in.
- The PDF writer is shared: the Mac's port of it (`PDFObjectWriter`, `PDFWriter`,
  `GlyphlessFont`, `GlyphlessCodes`, `PDFA`, `PDFEncryption`) writes the same bytes as
  `PdfObjectWriter`, `PdfBuilder`, `GlyphlessFont`, `PdfA` and `PdfEncryption` here, and the Mac
  writes every PDF through it: G4 pages, the Unicode text layer in the embedded glyphless font,
  PDF/A (the Archival switch and the Archive document task) and password-protected PDFs
  (AES-256). What stays each app's own is how the password is asked for (`PdfPasswordWindow`
  here, `PDFPasswordWindow` on the Mac) and moving the finished file into place (`WriteNewFile`
  here, `AppState.writePDFAtomically` on the Mac).
- Adding pages to an existing PDF: both write the same incremental update with their own reader
  (`PdfReaderLite`, `PdfAppender` here, `PDFReaderLite`, `PDFAppender` on the Mac), leaving the
  file's bytes as they were, and both refuse a password-protected file. What stays each app's own
  is putting the new file in place (`File.Replace` here, `FileManager.replaceItemAt` on the Mac).
  Nothing about it is stored on either.
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
- Rotate pages upright: the decision (which ways up are read, when one wins, the 3 s limit) is the
  same code on both platforms; the reading is the platform's own, Vision's fast recognizer on the
  Mac (lines it is more than 0.3 sure of) and Windows OCR's recognizer for the user's languages on
  Windows, so a page with little or unusual text can be turned on one and left on the other. Vision
  is always there; Windows needs an OCR language installed. The turn button sits under the page in
  the Mac strip and on the page on Windows.
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
  Text puts "\r\n" line breaks on the Windows clipboard and "\n" on the Mac pasteboard. Both read
  the pages first and hand the PDF writer their lines. The page pictures of a Word document are
  planned by the same code and packaged byte for byte the same, but encoded by each platform's
  own encoders (WIC here, ImageIO on the Mac), so the picture bytes differ; a black & white page
  is a 1-bit PNG on Windows and a gray PNG of 1 bit (or 8, as ImageIO writes it) on the Mac. A
  picture that cannot be encoded fails the save here (the pages stay queued); the Mac leaves that
  page without its picture.
- Receipts: finding, cleaning up and dating are the same code on both platforms, on the same gray
  copy, so the same scan gives the same regions and pixels; the dates come from different
  recognizers (Windows OCR here, Vision on the Mac), so a receipt can be dated differently. The
  day-or-month preference is the culture's short date pattern here and the Mac formatter's pattern
  for day, month and year there.
- PDF sizes: the plan is the same code on both platforms, and both embed the planned JPEG
  unchanged through the same writer (`PdfBuilder` here, its port `PDFWriter` on the Mac). Only the
  JPEG encoder differs (WIC here, ImageIO on the Mac), so the JPEG bytes, and with them the file
  sizes, differ a little; the sizes still need checking on a Mac (the Swift tests check the plan,
  the JPEGs and the size order).
- Black & white pages: the plan and the G4 bytes are the same on both platforms (CCITT G4 up to
  600 dpi at Standard, 300 dpi at Compact and Smallest; `CcittG4Encoder`, `Bilevel`, `BilevelTiff`
  and their Swift twins `CCITTG4Encoder`, `Bilevel`, `BilevelTIFF` share their golden values).
  Both write them as G4 into every PDF (the Mac writes every PDF, not only those with a black &
  white page, through its port of this writer) and every black & white TIFF (on the Mac also
  their turn in the Saved tab). Only the pixels differ where the pages come from different image
  pipelines (Core Image on the Mac).

## Windows Scan (backup connection)

WIA scanners can also be reached through Windows Scan, the WinRT `ImageScanner` API
(`Windows.Devices.Scanners`) that the Windows Scan app uses, over the same WIA 2.0 drivers. It
is a backup to the WIA Automation connection, never a replacement: nothing changes for a
scanner WIA Automation reaches unless the user picks it. It is Windows only; the Mac reaches the
same scanners through ImageCaptureCore.

- **Where it shows.** The same scanner listed by WIA and by Windows Scan is one row; its
  **via** menu offers "Windows Scan (backup)". The connection ranks after every other one
  (WIA, network, TWAIN), so it is used only when chosen there, or when it is the only
  connection left to the scanner, for example when WIA Automation lists nothing; the row is
  then captioned "Windows Scan (backup)". The choice is kept like any other connection choice
  (`preferredConnection` in `preferences.json`).
- **Not ahead of WIA.** Windows Scan lists a scanner as soon as it is plugged in, WIA
  Automation only on its next poll (10 s to a minute later). So a scanner only Windows Scan
  (or Windows Scan and TWAIN) lists is not chosen on its own until WIA Automation has looked
  again: the app has it enumerate at once, and waits for an enumeration that began after the
  scanner appeared (one already running when it appeared does not count). If WIA then lists
  it, WIA is used and Windows Scan is never opened; if not, Windows Scan is the connection
  left and is chosen. Meanwhile the row is listed and the user can pick it.
- **Finding scanners.** A device watcher on `ImageScanner.GetDeviceSelector()` lists the
  scanners that are plugged in and follows them being plugged in or out, without polling.
- **Without package identity.** The app is not installed as a package. Listing scanners and
  opening one work without package identity or any declared capability (checked on Windows 11:
  the watcher's first pass completes, and opening a device reaches WIA, which answers
  `WIA_S_NO_DEVICE_AVAILABLE` for one that is not there). Should Windows refuse the API
  (no package identity, access denied, or an edition without it) when the watcher starts or
  a device is opened, the connection lists nothing and `devices.txt` says "Windows Scan
  (backup): unavailable, connection hidden" and why; the other connections are not affected.
  An access denial from opening a device can also be that one device refusing (its driver, or
  the device held by another program), so it hides the connection only when no device has
  opened yet and every scanner Windows Scan lists has refused; until then only that scanner
  fails, and the others stay listed.
  Once a device is open the API works, so later errors (an access denial from the device, or
  the app's own temporary folder that cannot be written) fail that scan only. When Windows stops the watcher on its own,
  what it found stays listed, `devices.txt` says so, and the troubleshooter's **Refresh**
  starts it again.
- **What it reports.** The flatbed and the feeder as the device reports them (a feeder-only
  scanner offers no flatbed and no preview), the glass and the feeder's largest sheet, two-sided
  feeding, and the resolutions: Windows Scan gives only the smallest, largest and optical
  resolution, so the standard ladder between the first two is offered, nothing above the optical
  one (`ResolutionList.FromBounds`; a largest resolution the driver does not report is unknown,
  and the usual list is offered). The color modes, file formats and paper sizes each source
  takes, and whether it can measure the sheets itself, decide the request and are listed in
  `devices.txt` once a scanner has been opened. A device that offers neither a flatbed nor a
  feeder to configure is scanned with its own settings.
- **Scanning.** The resolution nearest the one asked for; the same color mode, or the nearest
  the source takes (black & white falls back to gray, which the app turns black and white
  itself); PNG, else TIFF, else BMP, else JPEG. The flatbed scans the selected area in inches
  (the whole glass without one). The feeder takes every sheet, both sides when asked and it
  can, and a paper size by name when it takes it (otherwise as an area), or measures each sheet
  for Automatic when it can (otherwise it scans its largest sheet). The device keeps its
  settings for the whole session, so every feeder scan states its area: the whole feeder, set
  before a size by name or measuring, unless the paper is asked for as an area. A feeder whose
  size it does not report gets no area to state: a scan that asks for no size by name there
  (Automatic, or a size it does not take by name) first puts back the page size and area the
  feeder had when the session opened, so an earlier scan's paper size does not stay. Pages are
  tagged with the resolution the driver reports; a device that configures itself reports none,
  and its pages take the resolution their file records (not 72 or 96 dpi, which stand for none),
  else the one asked for. Each scan writes its files to a new folder inside the app's own
  page spool (`%TEMP%\LazyScan-pages`), never to the user's folders, and the folder is
  deleted once the pages are read. A multi-page TIFF gives one page per frame.
- **Preview, cancel and errors.** The overview is the device's own preview when it makes
  one, otherwise a 150 dpi scan. Cancel cancels the running Windows operation. Errors become
  the same plain messages as WIA's (the WIA codes Windows Scan passes on, a device that went
  away, a broken link to the WIA service); a feeder batch that fails partway keeps the sheets
  already written and says why it stopped, and an empty feeder after some sheets just ends it.
- **To check on real hardware:** listing and grouping with the WIA entries (`devices.txt`),
  capabilities, flatbed, preview, feeder and two-sided scans and their page order, paper
  sizes and measured sheets, cancel during a long scan, a jam partway (the file names a partly
  scanned batch leaves), and a scanner unplugged while open.

## TWAIN

TWAIN reaches scanners whose makers ship only a TWAIN driver (many document scanners) or
whose TWAIN driver offers more than their WIA one. It is Windows only; the Mac reaches the
same scanners through ImageCaptureCore.

- **What it needs.** The TWAIN Data Source Manager (`C:\Windows\System32\TWAINDSM.dll`) that
  scanner drivers install. The app never ships it (it is LGPL). Without it the TWAIN backend
  lists nothing, and `%LOCALAPPDATA%\Lazy Scan\Logs\devices.txt` says
  "TWAIN: not installed"; the troubleshooter says so too and explains what installs it. The
  drivers are listed once, at start: a driver installed while TWAIN works appears after a
  restart (while TWAIN is missing or would not start, the troubleshooter's **Refresh** lists
  again). A listing that fails (the Data Source Manager would
  not open, or a driver held it up past 60 s) is tried again after 30 s, 1, 2 and then every
  5 minutes, and a listing that finishes late is still used.
- **32-bit drivers.** The app itself loads 64-bit drivers (`C:\Windows\twain_64`). A driver
  installed only for 32-bit programs (a `C:\Windows\twain_32` data source with no 64-bit
  counterpart, the Windows WIA bridge `wiatwain.ds` aside) is reached through a small 32-bit
  helper, `LazyScan.TwainHelper.exe`, next to `LazyScan.exe`:
  - It is started only when such a driver is installed, once per app session, and loads the
    32-bit Data Source Manager the drivers installed (`TWAINDSM.dll` in `SysWOW64`, or the
    `twain_32.dll` Windows has always had); it ships none. The same scan logic runs in the app
    as for 64-bit drivers; each TWAIN call goes to the helper (`RemoteTwainTransport`), and the
    pages come back in chunks.
  - Its sources are listed as TWAIN connections named "… (32-bit driver)" and captioned
    "TWAIN (32-bit driver)", leaving out those a 64-bit driver also offers and the WIA bridge
    ("WIA-…"). A scanner WIA or a 64-bit driver also reaches is one row; the 32-bit driver is
    then the last choice in its **via** menu and is used only when chosen.
  - The two talk over a named pipe with a random name that only the current user may open and
    that refuses network clients, created by the app for the one process it started (checked
    when the helper connects). Nothing listens on the network.
  - A helper that crashes ends the scan in progress with "stopped unexpectedly"; one that does
    not answer in time (the same limits as above), or whose driver will not stop scanning, is stopped
    and the scan says so. Unlike a driver stuck in the app itself, this never blocks later scans: the
    next scan or connection starts a new helper and opens the scanner again. Cancel works as above.
  - It ends with the app: it is in a job that Windows closes when the app exits or crashes, it
    watches the app's process, and it exits when the pipe closes.
  - It needs the 32-bit (x86) .NET 10 Desktop Runtime. Without it, or if the helper is missing,
    the 32-bit drivers are not listed, `devices.txt` says why ("TWAIN 32-bit helper: failed (…)"),
    and the troubleshooter still names them, with the fix (install the x86 runtime, reinstall
    Lazy Scan). It names them too while the helper's Data Source Manager is missing or
    lists no usable driver ("reached no usable driver" in `devices.txt`; that helper is stopped
    again). A driver window the helper opens belongs to the helper process, so it may appear behind
    the app's window.
  - A listing that fails for a reason that may pass (the helper slow to start, its Data Source
    Manager would not open, a driver holding it up) is tried again after 30 s, 1, 2 and then every
    5 minutes, and one that finishes after its time limit (the helper's own limits for starting,
    the handshake and the listing, plus 10 s) is still used. One that cannot pass on its own (no
    x86 runtime, the helper missing) waits for the troubleshooter's **Refresh**.
  - A source's resolutions cross the pipe as runs (first value, step, count), so a driver that
    reports a fine range such as 50 to 9600 dpi in 1 dpi steps offers the same resolutions as it
    would in-process.
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
  data source (installing it needs administrator rights). For the 32-bit helper: a real
  32-bit-only driver with `TWAINDSM.dll` and with the old `twain_32.dll`, its window, and a
  driver that crashes or hangs the helper.

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
  `http(s)://` URL. An IPv6 zone may be an interface number or name (`%12`, `%ethernet_32769`;
  a name is kept as its number), and one that names no interface is refused rather than
  dropped. It checks that an eSCL scanner answers there before adding it, and
  explains what is wrong when nothing does. Addresses are kept in
  `%APPDATA%\Lazy Scan\escl-hosts.json` (a JSON list of strings, the file earlier
  versions asked to edit by hand; hand-written entries keep working). They are checked at
  start, and ones that do not answer are tried again every minute. A row reached through an
  added address has **Remove address …** in its context menu; a scanner that is also found
  automatically stays listed.
- **HTTPS and certificates.** Scanners make their own certificates, which Windows cannot
  check. The first time the app connects to a scanner over HTTPS, its certificate is trusted
  and pinned (trust on first use): the SHA-256 of its public key is kept, with the scanner's
  UUID and the addresses it was seen at, in `%APPDATA%\Lazy Scan\escl-trust.json`. Only
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
- **Shared with the iPhone.** The protocol logic above has Swift twins in
  `Sources/LazyScanKit/Escl/` that behave the same way and pass the same tests:
  capabilities, the scan request (the same ScanSettings bytes), the status mapping, the retry
  policy, TXT records, addresses and their canonical text, one entry per scanner, the
  added-address list, the trust store with its validator, and since I11 the HTTP client and
  session (`EsclClient`, `EsclScannerSession`: the same job rules on URLSession, with each page
  downloaded to the page spool instead of read into memory, the system's background time held
  while a job runs, and a job the system suspends keeping its pages with the `AppSuspended`
  stop, which Windows never produces) and the way a scanner is connected to (the iPhone's
  `EsclScannerBackend`: addresses in order, trust on first use, a changed certificate refused,
  never plain HTTP after a refused certificate). Since I12 the iPhone also finds scanners on the
  network, keeps the addresses added by hand (the same `escl-hosts.json` format, the same messages
  as the Add scanner dialog) and shows the same troubleshooter checks for them. Two choices differ
  there: adding by address trusts a new certificate without asking (it is still pinned, and a
  changed one is asked about), and a connection that falls back to the scanner's own plain HTTP
  address after its HTTPS address could not be used (as Windows does) is labeled "Not encrypted". The fixtures both suites read are in
  `Tests/Fixtures/Escl`: capability documents, the request snapshots, a TXT record, scanner
  certificates (RSA-2048, P-256 and P-384) with their public-key fingerprints, a trust file
  written by each platform, and two test-only identities with their private keys
  (`tls-scanner-a.p12`, `tls-scanner-b.p12`) that the Swift suite's loopback HTTPS scanner
  serves; `EsclTrustTests.TheLoopbackIdentitiesHaveTheirFingerprints` checks their fingerprints
  here too. No key ships in either app. Each platform keeps its own `escl-hosts.json` and
  `escl-trust.json`, with the same keys; a trust file from the other platform loads with its
  pins, only the date each was trusted reads as unknown (Windows writes ISO 8601 text, the Swift
  side a number). The iPhone keeps an IPv6 zone in the URL text (`%25` and the zone), where
  `System.Uri` leaves it out of `AbsoluteUri`.
- **To check on real hardware:** discovery of real scanners (the names, TXT records and
  addresses they advertise appear in `devices.txt`), HTTPS with real scanner certificates
  and TLS versions, link-local IPv6 connections, and how long Windows keeps listing a
  scanner that was switched off (a service unregistered on this PC was still reported 30 s
  later; connecting to such a scanner fails with the usual message).

## Third-party notices

The app and its 32-bit TWAIN helper (not Core, not the Mac app) include these packages, unchanged,
each under its own license (the helper uses NTwain only):

- **ZXing.Net** 0.16.11 (barcode and QR separator sheets, and the phone pairing code) — by Michael Jahn, a port of ZXing ("Zebra Crossing") by the ZXing
  authors. Licensed under the Apache License, Version 2.0
  (<https://www.apache.org/licenses/LICENSE-2.0>); the package ships no NOTICE file.
  <https://github.com/micjahn/ZXing.Net>
- **NTwain** 3.7.6 — by Eugene Wang. Licensed under the MIT License.
  <https://github.com/soukoku/ntwain>
- **ONNX Runtime** 1.24.2 (`Microsoft.ML.OnnxRuntime`, the page corner model) — by Microsoft.
  Licensed under the MIT License. <https://github.com/microsoft/onnxruntime>
- **DocAligner FastViT-T8** (`Models\fastvit_t8_h_e_bifpn_256_fp32.onnx` next to the app, fetched by
  `scripts/fetch_docaligner.sh`) — by DocsaidLab, release 1.1.1. Licensed under the Apache License,
  Version 2.0; its license text is copied next to it (`Models\DocAligner-LICENSE.txt`).
  <https://github.com/DocsaidLab/DocAligner>

The tests also use PdfPig 0.1.16 (Apache-2.0), which is never shipped.

## Settings files

Presets, scan settings and app preferences are JSON files in `%APPDATA%\Lazy Scan\`
(`presets.json`, `settings.json`, `preferences.json`; the preferences hold the appearance,
the connection chosen per scanner and the TWAIN connections that use their driver's
window), next to the network scanners added by address (`escl-hosts.json`) and their
trusted certificates (`escl-trust.json`), and the phone link's paired phones
(`companion-devices.json`: this PC's id and each phone's id, name and the SHA-256 of its secret,
never the secret) and the networks receiving is allowed on (`companion-networks.json`); what phones
sent and what waits for them is under `%LOCALAPPDATA%\Lazy Scan\Companion`. The scan settings and presets remember the task
they were set up for as text (`"taskId": "document"`), left out when there is none, so a task
added by a newer version is kept by an older one. They also hold an `"output"` object with the
PDF size, the after-save action, the text beside a PDF, PDF/A and the password switch
(`"output": {"pdfSize": "standard", "afterSave": "none", "alsoSaveText": false, "archival": false,
"protect": false}`; never a password); a file without them, or with a value this version does not
know, reads as Standard, Do nothing, no text file and a plain PDF without a password.
Two-sided scanning and the paper size are top-level keys (`"duplex": "off"`, `"backBinding":
"longEdge"`, `"paperSize": "auto"`); a file without them, or with a value this version does not
know, scans one side on the whole area. Blank pages are in a `"document"` object
(`"document": {"removeBlankPages": false, "blankSensitivity": "medium", "autoCrop": false,
"autoStraighten": false, "autoRotate": false}`); a file without it keeps every page and leaves pages as scanned, and a
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
3. Both `swift test` (repo root) and `dotnet test` (this directory) must pass; CI also runs the
   shared Swift suite on the iOS Simulator and the iPhone app's UI smoke test (the `ios` job).
   Shared Swift code goes in `Sources/LazyScanKit`, which uses no AppKit, UIKit, SwiftUI or
   ImageCaptureCore; what only the Mac has goes in `Sources/LazyScanMac`, what only the
   iPhone and iPad have in `Sources/LazyScanIOS` (the app's project is `../ios/project.yml`).
