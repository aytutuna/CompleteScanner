# CompleteScanner for Windows

The Windows sibling of the macOS CompleteScanner app, following the **shared core, native
UI per platform** architecture:

- **`CompleteScanner.Core`** — a platform-neutral .NET 10 class library with **zero
  dependencies**: photo detection (thresholding → morphology → connected components →
  convex hull → rotating calipers), the image adjustment pipeline, naming templates,
  presets/settings persistence, a dependency-free searchable-PDF writer, the scanner
  backend contract, scanner problems with their user-facing text (`Troubleshooting.cs`),
  and the hardware-free demo scanner. It is a type-for-type port of the
  Swift `CompleteScannerKit` core (see `../CONTRACTS.md` for the shared conventions,
  especially the four coordinate systems). It also holds the testable protocol logic of the
  Windows-only backends, which has no Swift twin because macOS reaches the same scanners
  through ImageCaptureCore: the WIA error and document-handling tables (`WiaErrors.cs`),
  the eSCL capabilities parser, job request builder, 503 retry policy and status parser
  (`Escl/`), and the TWAIN scan logic (`Twain/`: the acquisition state machine behind an
  `ITwainTransport` interface, memory-strip and bitmap conversion, the paper-size table and
  the condition-code mapping). Device merging (`DeviceMerge.cs`: one row per physical
  scanner, whichever backends list it) is shared with macOS.
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

The main window has three tabs, like the macOS app:

- **Scan** — preview canvas, page queue and the settings inspector (Preview/Scan stay pinned
  at the bottom). Adjustment sliders are centered (-100…+100, 0 = neutral) and preview live
  on the canvas; queued pages can be reordered, rotated 90° or removed; detected photos open
  in a review where each crop can be corrected by hand. **Cancel** works in every busy phase
  (scanning, processing, photo detection, OCR, PDF writing, exports) and never leaves a
  partial file behind.
- **Scans** — this session's scans, newest first; click one to enlarge it.
- **Saved** — the destination folder's files, newest first, with open, show-in-Explorer and
  rotate-in-place for JPEG/PNG/TIFF.

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
**Document Feeder (ADF)** source delivers three numbered letter-size sheets per scan
(Preview is for the flatbed, so it is off while the feeder is selected).

## Status — what's verified vs. what needs scanner hardware

| Component | Status |
|---|---|
| Build | Builds on Windows 11 with the .NET 10 SDK |
| Core algorithms (detector, geometry, pipeline, naming, PDF) | Ported line-by-line from the tested Swift originals; **`dotnet test` passes** (the conformance suite mirroring the macOS tests) |
| Demo scanner + WPF shell | **Verified on Windows 11:** the app launches and connects to the Demo Scanner; driving the view-model, Photos-mode scans detect, re-crop and save the demo photos, Document-mode scans queue, rotate and save a multi-page PDF (with the OCR pass), cancelled scans/OCR/PDF saves leave no files, and scan history fills. All three tabs, the photo review and the crop editor were checked on screen (including the 700×560 minimum window); a hands-on interactive walkthrough is still to do |
| Windows OCR (`WindowsOcrService`) | **Verified on Windows 11** against rendered text (line boxes come back in the bottom-left-origin Core convention); needs a language pack installed |
| WIA backend (`WiaScannerBackend`) | **Experimental, untested against hardware** — documented WIA Automation flow; enumeration runs off the UI thread and re-polls (every 10 s backing off to 60 s while no scanner is present, every 60 s while one is), so scanners plugged in or unplugged later show up without a restart. The sources come from the device's document-handling capabilities, so a feeder-only scanner offers no flatbed and no preview; the feeder's sheet size and two-sided support are reported; a feeder batch uses one connection; WIA error codes become plain messages (an empty feeder says "Load paper in the feeder, then scan again."); a batch that fails partway keeps the sheets already scanned and tells the user how many were kept and why it stopped. Expect to iterate with a real scanner attached |
| One row per scanner (`DeviceMerge`, connection chooser) | Matching rules, ranking and the saved choice are covered by `DeviceMergeTests` (same table as macOS) and were checked by driving the view model with fake WIA and TWAIN backends: one row, WIA preferred, a later-appearing better connection taken over once the running scan ends, the user's choice saved and used at the next start, a choice made during a scan applied after it. A saved choice is keyed by the eSCL UUID or the model name, whichever the current set of connections yields, so it lapses when that set changes (see above). **Unverified with real drivers:** the names real WIA, eSCL and TWAIN drivers report; `devices.txt` collects them |
| TWAIN backend (`Scanning/Twain`) | **Experimental, untested against hardware** — see [TWAIN](#twain) below. The scan logic in Core (negotiation choices, the acquisition state machine, strip and bitmap conversion, paper sizes, error mapping, 32-bit driver detection) is covered by `TwainScanLoopTests`, `TwainRasterTests` and `TwainScanRequestsTests` through a fake transport. Driving the view model with the real session class over a scripted transport checked flatbed, feeder, preview, empty feeder, a jam after two sheets (pages kept, reason shown), cancel while the driver is silent (returns at once, the source is reset and disabled in the background), switching away (the source is closed without waiting), the driver-window switch and its saved choice (kept when connecting finds the scanner off), a driver stuck while enabling (reported after the start limit, the next scan refused at once, the late scan stopped when the driver answers), and that a scanner only TWAIN lists is never opened unless the user picks it. On a PC without a TWAIN Data Source Manager the backend lists nothing and `devices.txt` says why; the app starts normally. **Unverified:** real drivers, NTwain's message loop with them, the TWAIN Working Group sample source (not installed here) |
| eSCL backend (`EsclScannerBackend`) | **Experimental, untested against hardware** — no mDNS discovery yet; add scanners by IP/hostname in `%APPDATA%\CompleteScanner\escl-hosts.json`, e.g. `["192.168.1.50"]`. Feeder-only devices offer no flatbed or preview; feeder jobs ask for the feeder's own sheet size (at most 17 in tall); black & white is requested as grayscale and thresholded by the app, because most devices reject 1-bit JPEG; busy (HTTP 503) answers are retried for up to 60 s; relative job addresses are resolved; when a job fails, the scanner's status explains it (empty feeder, jam, cover open, …); a feeder job that fails partway (an error answer, a dropped or stalled connection, a page that cannot be read) keeps the pages already received and tells the user how many were kept and why it stopped; a job that is cancelled or cut short is deleted on the device. Checked against a local fake eSCL server, not a real device |

Known divergences from the macOS app (all documented in the source):

- `ImagePipeline` re-implements the Core Image filters as per-pixel math — visually close,
  not bit-identical; auto-enhance is a histogram auto-level rather than Apple's suggestion
  list.
- The demo scanner's document page draws text-shaped bars, not real glyphs (Core has no
  font rasterizer), so OCR demos need a real scan.
- WIA, eSCL and TWAIN exist only here, so their logic in Core (`WiaErrors.cs`, `Escl/`,
  `Twain/`) and its tests (`WiaErrorsTests`, `EsclTests`, `EsclRetryTests`,
  `TwainScanLoopTests`, `TwainRasterTests`, `TwainScanRequestsTests`) have no Swift
  counterparts: the Mac reaches the same scanners through ImageCaptureCore. The scanner
  problems they report (`ScannerProblem`) are shared with macOS.
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

## TWAIN

TWAIN reaches scanners whose makers ship only a TWAIN driver (many document scanners) or
whose TWAIN driver offers more than their WIA one. It is Windows only; the Mac reaches the
same scanners through ImageCaptureCore.

- **What it needs.** The TWAIN Data Source Manager (`C:\Windows\System32\TWAINDSM.dll`) that
  scanner drivers install. The app never ships it (it is LGPL). Without it the TWAIN backend
  lists nothing, and `%LOCALAPPDATA%\CompleteScanner\Logs\devices.txt` says
  "TWAIN: not installed". The drivers are listed once, at start: a driver installed while
  the app runs appears after a restart. A listing that fails (the Data Source Manager would
  not open, or a driver held it up past 60 s) is tried again after 30 s, 1, 2 and then every
  5 minutes, and a listing that finishes late is still used.
- **64-bit only.** The app can load only 64-bit drivers (`C:\Windows\twain_64`). Drivers
  installed only for 32-bit programs (`C:\Windows\twain_32`) are listed in `devices.txt` as
  "32-bit only" and cannot be used yet.
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
  already scanned and says why. Two-sided scanning is switched off for now (it comes with the
  two-sided milestone), so a driver that defaults to it still scans one side.
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

## Settings files

Presets, scan settings and app preferences are JSON files in `%APPDATA%\CompleteScanner\`
(`presets.json`, `settings.json`, `preferences.json`; the preferences hold the appearance,
the connection chosen per scanner and the TWAIN connections that use their driver's
window). They load across versions the same way as on macOS (`../CONTRACTS.md`, rule 6): a value this version does not understand resets only
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
