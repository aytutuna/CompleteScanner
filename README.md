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
- **Share, email, open with, copy**: after a save, and on every file in the Saved tab, open the
  file, open it with another app, show it in Finder, share it (Mail, Messages, AirDrop, …), start
  a Mail message with it attached, or copy it (an image also as a picture). **After saving** can
  open, show or share the files on its own; the Email a document task shares them. Nothing is
  sent without you sending it.
- **Two-sided scanning and paper size**: a feeder that scans both sides puts every sheet's
  front and back in page order; with a feeder that scans one side, scan the fronts, turn the
  stack over and scan the backs, and the app guides the two steps and puts the pages in order
  (it says so when the counts do not match: "3 fronts but 2 backs"). A stack larger than the
  feeder, or one that jams, is scanned a part at a time before turning it over. Back sides of
  sheets that flip on the short edge (like a calendar) are turned upright. The paper size (Letter, Legal,
  Executive, A4, A5, A6, B5, ID card, or Automatic) sets the sheet the feeder is asked for, and
  on the glass the area scanned from its corner when nothing is selected. Each page in the strip
  says which side of which sheet it is.
- **Blank pages**: every page collected for a PDF is checked for being blank as it is scanned,
  robust to scanner noise, dust, tinted or uneven paper, edge shadows, punched holes and the
  other side showing through. A blank-looking page is only flagged in the page strip; with
  **Skip blank pages** on it is dimmed, marked "Blank, skipped" and left out when the PDF is
  saved, and one click on **Keep** saves it after all (**Skip** leaves out any flagged page by
  hand). **What counts as blank** (Low, Medium, High) sets how much may be on a blank page: a
  lone page number counts as blank at Medium, one line of text or a signature never does. Pages
  saved as soon as they are scanned are never left out. The Two-sided document task skips blank
  pages, since one-sided sheets have empty backs.
- **"Why isn't my scanner listed?"**: a troubleshooter, from the **?** button next to
  **Scanners**, the empty scanner list and an error about a scanner. It checks, in plain
  language, whether macOS is looking for scanners and what the last failure was (a scanner that
  is busy in another app or reported a problem). For what macOS does not let it check, it gives
  tips: a USB scanner needs its maker's driver, a network scanner must be on the same network
  and the Local Network permission allowed, and a shared scanner needs Scanner Sharing on the
  other Mac. It offers **Refresh**, **Open Image Capture**, **Open Printers & Scanners** and
  **Copy Diagnostics**. It only reads; it never changes a setting. On Windows it also checks
  the Windows Image Acquisition service, the network profile (Public networks hide scanners),
  TWAIN and 32-bit-only TWAIN drivers, and addresses added by hand.
- **Image adjustments**: auto-enhance, brightness / contrast / saturation / sharpness,
  descreen (moiré reduction for printed material), faded-color restoration for old photos,
  black-and-white threshold.
- **Start screen**: pick what you are scanning (Document to PDF, Multi-page from feeder,
  Photos, Old photo restoration, Quick scan, Email a document, Two-sided document) and everything is set up for it, with a short
  guide on the scan screen. Tasks the connected scanner cannot do are greyed out with the
  reason. The app remembers the task you used last.
- **Presets**: save your own settings as presets; they appear on the start screen too.
  Starter presets from earlier versions stay.
- **File naming templates**: `{date}`, `{time}`, `{counter}`, `{counter:4}`, `{intent}`,
  `{index}`, `{task}` tokens; automatic collision-free numbering.
- **Demo Scanner**: a built-in simulated device so you can try every feature (including OCR,
  photo splitting and a document feeder with three two-sided sheets, which it scans one side or
  both; the second sheet's back is blank) with no hardware connected.

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
  driver, then click the refresh button in the sidebar. **Why isn't my scanner listed?** (the
  **?** next to **Scanners**) walks through the usual causes.
- A scanner reachable several ways (an MFP on USB and on the network) is listed once. The app
  connects over USB when it can, then over the network, then through a shared Mac. The names
  the devices report, how they were matched and the troubleshooter's checks are written to
  `~/Library/Logs/CompleteScanner/devices.txt`; **Copy Diagnostics** in the troubleshooter
  copies the same text.

## Project layout

- `Sources/CompleteScannerKit/Core` — shared models + backend protocols
- `Sources/CompleteScannerKit/Backends` — ImageCaptureCore backend, demo backend
- `Sources/CompleteScannerKit/Pipeline` — photo detection/split/deskew, image adjustments, the
  page clean-up stage (`PageProcessor`: blank-page check, then adjustments) and its image
  toolkit (`RgbaImage`, `GrayImage`, `BackgroundMap`, `MaskOps`, `BlankPageDetector`)
- `Sources/CompleteScannerKit/Output` — PDF builder, OCR, image export, naming templates
- `Sources/CompleteScannerKit/UI` — SwiftUI views
- `Tests/CompleteScannerTests` — unit tests (synthetic-image based)
