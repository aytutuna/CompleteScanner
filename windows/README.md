# CompleteScanner for Windows

The Windows sibling of the macOS CompleteScanner app, following the **shared core, native
UI per platform** architecture:

- **`CompleteScanner.Core`** — a platform-neutral .NET 10 class library with **zero
  dependencies**: photo detection (thresholding → morphology → connected components →
  convex hull → rotating calipers), the image adjustment pipeline, naming templates,
  presets/settings persistence, a dependency-free searchable-PDF writer, the scanner
  backend contract, and the hardware-free demo scanner. It is a type-for-type port of the
  Swift `CompleteScannerKit` core (see `../CONTRACTS.md` for the shared conventions,
  especially the four coordinate systems).
- **`CompleteScanner.Core.Tests`** — the conformance suite: the macOS test cases ported to
  xUnit with the same fixtures, geometry, and tolerances. **This is the contract that keeps
  the Swift and C# cores behaviorally identical** — change an algorithm on one side, port
  the change, and both suites must stay green.
- **`CompleteScanner.App`** — the native Windows shell (WPF, .NET 10): main window with
  sidebar/inspector/preview-canvas/page-strip/photo-review, a view-model porting the macOS
  `AppState` orchestration, and Windows service implementations (WIA + eSCL scanning,
  Windows.Media.Ocr, WPF imaging codecs).

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

Pick **Demo Scanner** in the sidebar to exercise everything without hardware: scan in
Photos mode to see detection/deskew/review, or Document mode to build a PDF.

## Status — what's verified vs. what needs scanner hardware

| Component | Status |
|---|---|
| Build | Builds on Windows 11 with the .NET 10 SDK |
| Core algorithms (detector, geometry, pipeline, naming, PDF) | Ported line-by-line from the tested Swift originals; **`dotnet test` passes** (the conformance suite mirroring the macOS tests) |
| Demo scanner + WPF shell | **Verified on Windows 11:** the app launches and connects to the Demo Scanner; driving the view-model, Photos-mode scans detect, re-crop and save the demo photos, Document-mode scans queue, rotate and save a multi-page PDF (with the OCR pass), cancelled scans/OCR/PDF saves leave no files, and scan history fills. All three tabs, the photo review and the crop editor were checked on screen (including the 700×560 minimum window); a hands-on interactive walkthrough is still to do |
| Windows OCR (`WindowsOcrService`) | **Verified on Windows 11** against rendered text (line boxes come back in the bottom-left-origin Core convention); needs a language pack installed |
| WIA backend (`WiaScannerBackend`) | **Experimental, untested against hardware** — documented WIA Automation flow; enumeration runs off the UI thread and re-polls (every 10 s backing off to 60 s while no scanner is present, every 60 s while one is), so scanners plugged in or unplugged later show up without a restart; expect to iterate with a real scanner attached |
| eSCL backend (`EsclScannerBackend`) | **Experimental, untested against hardware** — no mDNS discovery yet; add scanners by IP/hostname in `%APPDATA%\CompleteScanner\escl-hosts.json`, e.g. `["192.168.1.50"]` |

Known divergences from the macOS app (all documented in the source):

- `ImagePipeline` re-implements the Core Image filters as per-pixel math — visually close,
  not bit-identical; auto-enhance is a histogram auto-level rather than Apple's suggestion
  list.
- The demo scanner's document page draws text-shaped bars, not real glyphs (Core has no
  font rasterizer), so OCR demos need a real scan.
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

## Porting workflow

When an algorithm changes on either side:

1. Change the implementation and its test in that platform's suite.
2. Port both to the other platform (the sources carry matching structure and comments —
   `PhotoDetector.cs` is diffable against `PhotoDetector.swift` stage by stage).
3. Both `swift test` (repo root) and `dotnet test` (this directory) must pass.
