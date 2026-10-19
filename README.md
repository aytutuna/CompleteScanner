# CompleteScanner

A one-stop, native macOS scanning app: documents to (searchable) PDF, and batch photo
scanning that automatically finds, straightens, and splits multiple photos laid on the
flatbed into separate JPEG/PNG files.

Built with SwiftUI on Apple's **ImageCaptureCore**, so it works with any scanner that has a
macOS driver (Epson, Canon, HP, Brother, …) as well as driverless **AirScan/eSCL network
scanners** — including the Epson Perfection V39 II.

## Features

- **Any scanner**: USB scanners via their macOS (ICA) driver, plus network/shared scanners
  discovered over Bonjour. Flatbed and document-feeder (ADF) sources.
- **Document mode**: scan pages into a queue, reorder/delete, then save one multi-page PDF.
  Optional **searchable PDF** — OCR (Apple Vision) embeds an invisible text layer so the PDF
  is selectable and searchable. Or save every scan immediately as its own PDF/JPEG/PNG/TIFF.
- **Photo batch mode**: lay several photos on the glass, press Scan once. The app detects
  each photo, measures its tilt, deskews and crops each one, and shows a review grid —
  untick false positives, rotate, then save all as separate JPEG/PNG/TIFF files with correct
  DPI metadata. Repeat with the next batch.
- **Preview & area selection**: fast overview scan of the bed, drag a marquee (with physical
  inch dimensions shown) to scan only part of the glass.
- **Full scan control**: resolution (from the scanner's real supported list), color /
  grayscale / black-and-white, JPEG quality, DPI-correct output.
- **PDF size**: Best, Standard, Compact or Smallest. Smaller sizes store the page images at
  a lower resolution (300, 200 or 150 dpi at most) and with more JPEG compression; gray pages,
  and pages scanned in color that have no color, are stored as gray. The page size stays the
  same and text recognition always reads the full scan. The size alone sets the JPEG quality
  of PDF pages (Best 0.9, Standard 0.8, Compact 0.65 / 0.7 gray, Smallest 0.5 / 0.55 gray);
  the JPEG quality setting is for JPEG files.
  **Behavior change:** Standard is the new default for everyone, including existing settings
  and presets; earlier versions always wrote full-resolution color JPEGs (choose Best for
  that). On the Mac each page is encoded as a JPEG with ImageIO and handed to the CoreGraphics
  PDF writer as a JPEG-backed image, which stores it unchanged; that the files come out as
  small as on Windows still has to be confirmed on a Mac. Black & white pages are gray JPEGs
  for now (no CCITT G4 yet).
- **Image adjustments**: auto-enhance, brightness / contrast / saturation / sharpness,
  descreen (moiré reduction for printed material), faded-color restoration for old photos,
  black-and-white threshold.
- **Start screen**: pick what you are scanning (Document to PDF, Multi-page from feeder,
  Photos, Old photo restoration, Quick scan, Email a document) and everything is set up for it, with a short
  guide on the scan screen. Tasks the connected scanner cannot do are greyed out with the
  reason. The app remembers the task you used last.
- **Presets**: save your own settings as presets; they appear on the start screen too.
  Starter presets from earlier versions stay.
- **File naming templates**: `{date}`, `{time}`, `{counter}`, `{counter:4}`, `{intent}`,
  `{index}`, `{task}` tokens; automatic collision-free numbering.
- **Demo Scanner**: a built-in simulated device so you can try every feature (including OCR,
  photo splitting and a three-sheet document feeder) with no hardware connected.

## Build & run

Requires Xcode (or its toolchain) on macOS 14+.

```bash
cd ~/CompleteScanner
swift run CompleteScanner          # run directly
# or build a double-clickable app:
./scripts/make_app.sh              # -> dist/CompleteScanner.app
open dist/CompleteScanner.app
```

Run the test suite (photo detection, PDF/OCR, naming, adjustments):

```bash
swift test
```

## Windows version

A native Windows sibling app lives in [windows/](windows/) — same architecture (shared
platform-neutral core + native shell), with the photo detector and pipeline ported to a
dependency-free C# library, the same conformance test suite in xUnit, a WPF UI, and
WIA/eSCL scanner backends. See [windows/README.md](windows/README.md) for build
instructions and current status.

## Using it

1. Pick your scanner in the sidebar (or **Demo Scanner** to explore).
2. On **Start**, pick a task; or go to **Scanner** and choose a mode yourself:
   - **Document** — each Scan adds a page to the strip at the bottom; press **Save PDF**
     when done. Turn on *Searchable PDF (OCR)* for selectable text.
   - **Photos** — place several photos on the glass with a little space between them, press
     **Scan**, review the detected photos in the grid, then **Save N Photos**. Put the next
     batch on the glass and scan again.
3. **Preview** does a quick overview pass; drag on the image to restrict the scan area.
4. Set resolution, color mode, format, destination folder and naming in the inspector.

## Scanner support notes

- **Epson Perfection V39 II** (and other Epson Perfection models): install "Epson Scanner
  Driver" / *Epson Scan 2* from Epson's macOS downloads if the scanner doesn't appear.
  Once the driver is installed the scanner shows up in CompleteScanner automatically.
- Any scanner visible to Apple Image Capture will appear here too — that includes most
  Canon/HP/Brother/Fujitsu devices and all AirScan/eSCL network scanners.
- If a USB scanner is missing: check the cable/power, then install the manufacturer's macOS
  driver, then click the refresh button in the sidebar.
- A scanner reachable several ways (an MFP on USB and on the network) is listed once. The app
  connects over USB when it can, then over the network, then through a shared Mac. The names
  the devices report, and how they were matched, are written to
  `~/Library/Logs/CompleteScanner/devices.txt`.

## Project layout

- `Sources/CompleteScannerKit/Core` — shared models + backend protocols
- `Sources/CompleteScannerKit/Backends` — ImageCaptureCore backend, demo backend
- `Sources/CompleteScannerKit/Pipeline` — photo detection/split/deskew, image adjustments
- `Sources/CompleteScannerKit/Output` — PDF builder, OCR, image export, naming templates
- `Sources/CompleteScannerKit/UI` — SwiftUI views
- `Tests/CompleteScannerTests` — unit tests (synthetic-image based)
