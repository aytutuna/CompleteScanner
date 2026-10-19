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
  `RgbaImage.cs`), starting with blank-page detection (`BlankPageDetector.cs`).
- **`CompleteScanner.Core.Tests`** — the conformance suite: the macOS test cases ported to
  xUnit with the same fixtures, geometry, and tolerances. **This is the contract that keeps
  the Swift and C# cores behaviorally identical** — change an algorithm on one side, port
  the change, and both suites must stay green.
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
dotnet test                                  # run the conformance suite
dotnet run --project CompleteScanner.App     # launch the app
```

The main window has four tabs, like the macOS app:

- **Start** — "What are you scanning?": one card per task (Document to PDF, Multi-page from
  feeder, Photos, Old photo restoration, Quick scan, Email a document, Two-sided document) and the user's own presets, each badged
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
makes it deliver sheets of that size.

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
| Blank pages (`BlankPageDetector`, `PageProcessor`, `PageFilter`, image toolkit) | Covered by `BlankPageDetectorTests`, `PageProcessorTests`, `GrayImageTests`, `RgbaImageTests`, `MaskOpsTests` and the blank-page cases of `ModelsCompatTests`, `ScanTaskTests` and `MockScannerTests` (same cases as macOS; `MaskOpsTests` also pins PhotoDetector's regions on the demo bed to the last bit, unchanged by moving the mask code out of it). Checked on public-domain scans of letters, menus and photos (none taken for blank, at any level, with or without their dark surroundings) and on blank backs made from them (all found blank), and by driving the view model with the demo scanner (flagging, Skip blank pages turned on and off with pages queued, Keep and Skip per page, rotating a flagged page, saving 5 of 6 pages, nothing to save, pages saved at once keeping every page, the two-sided task, turning over by hand) and by building the window without showing it: the switch, the levels, the badges, Keep and Skip, the strip label, Save PDF's count, rendered off screen in light and dark. **Unverified:** blank backs from real scanners (see [Blank pages](#blank-pages)) |
| Share, email, open with, copy (`SaveActions`, `FileActions`, `ShareService`) | The choices are covered by `SaveActionsTests` and the after-save cases of `ModelsCompatTests` (same cases as macOS). Checked by driving the view model's real save paths with a stand-in for Windows (each after-save action after a PDF, a file saved at once and a photo batch; the Email task sharing; no share window; a refused action; a moved file; a cancelled save running nothing), by building the real clipboard data and share package without placing them anywhere, and by building the window without showing it: the bar, its buttons and menu, the narrow layout, the "After saving" choices, the Saved tab's buttons and menus, rendered off screen in light and dark. **Not tried on screen:** the share window, the Open with dialog and the clipboard themselves (checks must not send, open or overwrite anything), and Mail or Outlook as share targets |
| Troubleshooter (`Troubleshooter`, `SystemDiagnostics`, `TroubleshooterWindow`) | The checks are covered by `TroubleshooterTests` (same cases as macOS) and the Windows service and network values by `WindowsSystemStatusTests`. Checked by driving the view model with stand-in connections and a stand-in for Windows (the snapshot, the order of the checks, devices.txt, Refresh, Copy diagnostics and Settings refused, a busy scanner at connect and at scan, a connection that works clearing it, a cancelled scan not counting), by reading the real WIA service and network on Windows 11 (Running and Public, as `sc query` and `Get-NetConnectionProfile` report, from UI and thread-pool threads), by copying to the real clipboard with the user's clipboard saved and restored, by an address added by hand on loopback where nothing listens, by a discovered scanner (a stand-in service for a loopback scanner) that stays listed, selected and connected across a Refresh when Windows aborts either network watcher, and dropped only once the restarted watcher's first pass did not find it again, and by building the sidebar, error bar and troubleshooter window without showing them: the header button, the empty state's links, the error bar's Troubleshoot (and none on a file or photo error shown later), one card per check with its buttons and screen-reader names (each card a named group in the UI Automation tree), a Refresh while one runs ignored, rendered off screen in light and dark. **Not tried on screen:** opening Windows Settings and the real Add scanner dialog from it. **Unverified:** a stopped or disabled WIA service, a TWAIN install with 32-bit-only drivers, and a scanner that is really busy in another app |
| eSCL backend (`EsclScannerBackend`) | **Experimental, untested against hardware** — see [Network scanners](#network-scanners-escl) below for discovery, adding by address and HTTPS. Feeder-only devices offer no flatbed or preview; feeder jobs ask for the paper size's region, clamped to the feeder (the feeder's own sheet size for Automatic, at most 17 in tall); two-sided feeder jobs send `<scan:Duplex>true</scan:Duplex>` and use the two-sided feeder's capabilities (`AdfDuplexInputCaps`) when the device lists them, and a device that lists no two-sided feeding scans one side and says so; black & white is requested as grayscale and thresholded by the app, because most devices reject 1-bit JPEG; busy (HTTP 503) answers are retried for up to 60 s; relative job addresses are resolved; when a job fails, the scanner's status explains it (empty feeder, jam, cover open, …); a feeder job that fails partway (an error answer, a dropped or stalled connection, a page that cannot be read) keeps the pages already received and tells the user how many were kept and why it stopped; a job that is cancelled or cut short is deleted on the device. The protocol client (`EsclClient`, `EsclScannerSession`) is covered by `EsclClientTests` through a stub HTTP handler. Checked against local fake eSCL servers (plain and HTTPS), not a real device |

Known divergences from the macOS app (all documented in the source):

- `ImagePipeline` re-implements the Core Image filters as per-pixel math — visually close,
  not bit-identical; auto-enhance is a histogram auto-level rather than Apple's suggestion
  list.
- The demo scanner's document page draws text-shaped bars, not real glyphs (Core has no
  font rasterizer), so OCR demos need a real scan.
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
(`"document": {"removeBlankPages": false, "blankSensitivity": "medium"}`); a file without it keeps
every page, and a sensitivity this version does not know reads as Medium. A first run starts without presets: the task
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
