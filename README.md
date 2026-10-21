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
- **Text: Word documents, text files, Copy Text**: save the collected pages as a **Word
  document (.docx)** or a **text file (.txt)** with the recognized text instead of the pictures,
  or tick **Also save text (.txt)** to get a text file next to the PDF of the pages; **Copy Text** in a
  queued page's menu puts its text on the clipboard. The lines OCR finds are put in reading order
  (columns, tables of dishes and prices, a letterhead beside the text) and split into paragraphs;
  OCR reads each page once per save. The files are written without any library: a minimal Word
  package (the first page's paper size) that both platforms write byte for byte the same, and
  UTF-8 text with a blank line between paragraphs. **Include page images** (on by default) puts
  each page's picture, fitted to the paper, before its editable text, so the text can be checked
  against the page; the pictures are stored as the PDF size stores pages (JPEG, or a lossless
  1-bit PNG for black & white), and turning it off gives a text-only document. A Word document
  that would pass 2 GB is refused with a message and the pages stay queued. When no OCR language is installed
  (Windows) the save says so and names the setting.
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
  small as on Windows still has to be confirmed on a Mac.
- **Black & white as CCITT G4** (Windows for now): black & white pages are stored as lossless
  1-bit CCITT Group 4 images, in every PDF (at every size, up to 600 dpi at Standard and 300 dpi
  at Compact and Smallest; also PDF/A, password-protected and added pages) and in TIFF files
  (compression 4, one page or several). A 300 dpi letter page is 33 KB instead of a 527 KB gray
  JPEG at Standard. The encoder is the app's own code, with no library. The Mac stores black &
  white pages as gray JPEGs and writes LZW TIFFs until it gets the Windows PDF writer's port.
- **Archival PDF (PDF/A)** (Windows for now): a switch under the PDF size, and an **Archive
  document** task, save PDF/A-2b files for long-term keeping, with their color profile, fonts and
  description inside. On Windows the invisible text layer is now written in a small font
  embedded in the file, so text in any script (Turkish, Greek, Cyrillic, Arabic, Chinese, …)
  can be selected and searched. The Mac gets both with the port of the Windows PDF writer;
  until then it keeps its CoreText text layer, and the setting is kept in its settings file.
- **Password-protected PDFs** (Windows for now): **Require a password** encrypts saved PDFs
  with AES-256 (the PDF 2.0 standard security handler). The password is asked for at each save,
  typed twice, with a hint about its strength, and never stored; printing and copying can be
  disallowed, which PDF apps honor as a request, not a lock. A PDF/A file can't have a password,
  so the two switches exclude each other. The Mac gets it with the port of the Windows PDF
  writer; until then it keeps the switch in its settings file and writes no protected PDFs.
- **Add pages to an existing PDF** (Windows for now): **Add to existing PDF…** under the queue,
  or a PDF's menu in the Saved tab, adds the scanned pages to the end of a PDF you pick, such as
  a signature page for a contract. The file's existing bytes are kept as they are (the pages are
  added as an incremental update), and the file is replaced only once the new one has been
  written and checked. Password-protected and damaged files are refused; signed files and PDF/A
  files that may not stay PDF/A are asked about first. The Mac will add pages with PDFKit.
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
- **Crop and straighten**: **Crop to page** cuts each page out of the scanner's background and
  **Straighten pages** turns a page that lies at a slant straight, by the edges of the sheet or,
  without a visible edge, by its lines of text. Both are cautious: a page whose edges or text are
  unclear is left as scanned, a crop never cuts into the sheet, and turning a page never cuts off
  anything in its corners. A changed page has a small arrow in the page strip that shows it as
  scanned, and back. The Two-sided document task straightens pages.
- **Photos of documents**: no scanner needed. **Import photos of documents…** (or drop photo files
  on the window) adds phone photos of pages (JPEG, PNG, HEIC, TIFF, BMP, WebP) to the page queue:
  each photo is turned upright by its orientation tag, the page's four corners are found, and the
  page is cut out with its perspective corrected and cleaned up like a scan. When the page is not
  found clearly, a corner editor (with a magnifier) asks you to place the corners, or to use the
  whole photo, or to skip it. The page gets the resolution of the paper size its shape matches (A4,
  Letter, Legal, ID-1), else 200 dpi, is labelled **Photo** in the page strip, and one click shows
  it as photographed. The photo files themselves are only read, never changed or moved. On Windows,
  HEIC photos need Microsoft's free HEIF Image Extensions.
- **Send from your phone** (Windows now): pair a phone once by scanning a QR code on the PC, and
  documents scanned with CompleteScanner on the phone are added to the PC's page queue on their own,
  labelled **From phone**. The phone and the PC talk directly, encrypted and pinned to the PC's own
  key, with no account and no server; the PC listens only on networks you trust (Windows' Private
  networks, and ones you allow in the app, such as your school's Wi-Fi) and only while a phone is
  paired or a pairing code is shown. The iPhone app and the Mac's side follow.
- **Rotate pages upright**: a page put in upside down or sideways is turned the right way up by
  reading its text (Vision on the Mac, Windows OCR on Windows). Only a page whose text reads clearly
  better one way is turned; blank pages, separator sheets, photos and pages the reading is unsure
  about are left as scanned. A turned page has a small turn button in the page strip that turns it
  back as scanned, and again. The Two-sided document task turns pages upright.
- **ID card**: copies of an ID card or driving licence for a bank, a rental or a job. Scan the
  front, turn the card over where it lies and scan the back (or skip it when nothing is printed
  there); the card is found on the glass, cut out and straightened, and both sides go on one A4 or
  Letter page at their real size (85.60 × 53.98 mm): the paper in your default printer when it holds
  A4 or Letter, else the paper usual where you live, unless you pick the other. Check the sides, turn or re-crop one, swap them or scan one again, then save a PDF, or a
  JPEG, PNG or TIFF of the page, and if you like each side as an image too. ID cards are sensitive,
  so nothing leaves the Mac: the scans are kept in memory only, never in the Scans tab, and are
  cleared as soon as the card is saved or discarded; the PDF has no searchable text layer unless you
  turn it on. **Print** prints the page at real size on the printer chosen for copies.
- **Photocopy**: a photocopier from a scanner and a printer. Put the original on the glass (or a stack in
  the feeder) and press **Copy**: it is scanned and printed at real size, 1 inch on the glass is 1
  inch on paper, never scaled to the page unless you turn on **Fit to page**. Choose the printer
  (the default one unless you pick another), the number of copies (1 to 99) and color or gray; on
  the glass with Automatic paper size the part of the glass the printer's paper covers is copied,
  and an area selected on the preview is centred on the paper. The app says when the printer's
  margins cut the edges ("Edges may lose up to 5 mm"). **Also save a PDF** keeps a copy as a
  file too. **Print test ruler** prints a 1-inch grid with centimetre ticks to check the size
  with a ruler. On the Mac the standard print panel opens, already set to the printer, the paper,
  the copies and 100 %; on Windows the copy goes straight to the printer with no dialog.
- **Receipts**: lay several receipts on the glass (with a little space between them) and scan
  once. Each receipt is found, cut out along its paper (or, for thermal paper that hardly shows on
  a white lid, around its print), straightened, and cleaned up for faded thermal print: gray, the
  paper evened out to white, the print darkened. Check them in the review (untick, turn, fix a
  crop), then save: a small searchable PDF each (Compact size, gray), or one PDF for all of them,
  or JPEG, PNG or TIFF. Files are named by the date printed on the receipt (`{docdate}`): it is
  read from the receipt's text in ISO, US, European and Turkish numeric forms (2026-03-12,
  03/12/2026, 12.03.2026, 12-03-26), with month names in English, Turkish, German, French,
  Spanish, Italian, Portuguese and Dutch (12 Mar 2026, 12 Mart 2026, 12. März 2026), and in
  Chinese, Japanese and Korean, preferring a line that says "Date", "Tarih", "Datum"… and leaving
  out expiry and "valid until" dates; today's date is used when none is found. The text is read
  once per receipt, for the date, the PDF's text layer and, if you like, a .txt beside each PDF.
  From the feeder, each sheet is one receipt.
- **Separate documents**: feed a whole stack of documents at once and get a file for
  each. Put a separator sheet in front of every document after the first: **Save sheet** saves
  one as a PDF to print at actual size on any printer, and **Print sheet** prints one at once (a Patch T sheet, the standard patch code document scanners use; any patch
  code works, either way round, at a slant of a few degrees). Instead of separator sheets the stack
  can be split at empty sheets (with both sides scanned, only a sheet empty on both sides splits,
  so the blank backs of one-sided pages do not), every few sheets, or **at barcode or QR sheets**:
  a sheet with a QR code, Code 128, Code 39 or Data Matrix code starting with `CS-SEP` is left out
  and the rest of the code's text names the document after it (`{label}`); other codes, such as a
  payment QR code on an invoice, are ignored. **Save QR separator sheet** and **Print QR separator
  sheet** make such a sheet with the name you type, or with none for a sheet that only splits. With
  **A barcode starts a new document and names it**, a page carrying its own code (an invoice, say)
  is kept as the first page of a new document named after the code. Separator pages are not saved,
  and saving clears them from the queue with the rest: keep a page in the strip if it was taken for
  one by mistake. Codes are read with Vision on
  the Mac (no library) and anywhere on the page, at a slant. Nothing is split behind your
  back: the page strip shows each document before saving, separator pages are marked and left
  out, one click on the gap between two pages starts a new document there or joins it to the one
  before, a separator page can be kept, and a document can be named (`{label}` in the file name).
  **Save 3 PDFs** writes them all or nothing: a save that fails or is cancelled leaves no file
  and keeps the pages. Word and text files are split the same way.
- **Book or magazine**: scan an open book two pages at a time. Lay it face down with the spine
  in the middle of the glass, press it gently flat and press **Scan spread**, then turn the page
  and scan the next spread. Each spread is cut at the spine into its two pages, found by the spine's
  shadow or, on a book pressed flat, by the blank inner margins, and the pages go into the PDF in
  reading order: left then right, or right then left for Arabic, Hebrew or manga (**Reads right to
  left**). A book lying sideways on the glass is handled too: its pages are turned upright by reading
  their text, or by **Turn the pages**, and put in order the way they lie once turned. Each page is
  straightened on its own and blank pages are flagged. **Soften spine shadow** (on for this task)
  lifts the dark shadow along the spine of each page back towards the paper's white while the text
  stays dark, and leaves pictures beside the spine as they are; the arrow on a page shows it as
  scanned, and back. When the spine is not clear (a picture across
  it, a centered title page with no shadow) the spread stays one page, marked "not split"; a page's
  right-click menu splits a spread by hand (drag the cut to the spine), moves the cut, or joins the
  two pages again. **Split facing pages** works for any collected document scan of one side of each
  sheet, not only the task; pages scanned on both sides are kept as scanned.
- **"Why isn't my scanner listed?"**: a troubleshooter, from the **?** button next to
  **Scanners**, the empty scanner list and an error about a scanner. It checks, in plain
  language, whether macOS is looking for scanners and what the last failure was (a scanner that
  is busy in another app or reported a problem). For what macOS does not let it check, it gives
  tips: a USB scanner needs its maker's driver, a network scanner must be on the same network
  and the Local Network permission allowed, and a shared scanner needs Scanner Sharing on the
  other Mac. Its headline is one line ("No scanner found · 1 warning"); each check shows one line
  with its buttons (**Image Capture**, **Printers & Scanners**), and **More help** holds the rest;
  **Refresh** and **Copy Diagnostics** are at the bottom. It only reads; it never changes a setting. On Windows it also checks
  the Windows Image Acquisition service, the network profile (Public networks hide scanners),
  TWAIN and 32-bit-only TWAIN drivers, and addresses added by hand.
- **Image adjustments**: auto-enhance, brightness / contrast / saturation / sharpness,
  remove print dots (descreen, moiré reduction for printed material), faded-color restoration for
  old photos, black-and-white threshold.
- **Start screen**: pick what you are scanning, in three groups: **Documents** (Document to PDF,
  Stack from feeder, Two-sided document, Separate documents, Scan to Word, Email a document; on
  Windows also Archive document), **Photos & images** (Photos, Restore old photos, Quick scan) and
  **Other** (ID card, Photocopy, Receipts, Book or magazine). A tile is an icon and a title; what
  the task does and what it sets are its help. Picking one sets everything up for it, with a one-line
  guide on the scan screen and the fuller guidance behind its info button. Tasks the connected
  scanner cannot do are greyed out with a short reason ("Needs a document feeder", "Needs a
  printer"). The app remembers the task you used last.
- **Less text, same clarity** (both apps): icons and short labels on screen, explanations one hover
  or one click away. The scan settings are in sections; the task's own section, Scanner and Output
  start open, the others collapsed with a summary of what is on in them ("Skip blank · Upright +1"),
  and a task opens the section it needs. What a control does is its help (tooltip and VoiceOver); a
  line under a control stays only for why it is greyed out ("Needs the feeder", "Not with
  two-sided"), for a consequence ("Check flagged pages before saving") or for live state ("Using the
  selected area", "Last PDF: 498 KB"). The status line shows six words at most ("6 pages added · 1
  blank"); VoiceOver and Narrator read the whole sentence. An error is titled by the scanner's
  problem ("Paper jam", "Scanner offline") and says what to do.
- **Presets**: save your own settings as presets; they appear on the start screen too.
  Starter presets from earlier versions stay.
- **File naming templates**: `{date}`, `{time}`, `{counter}`, `{counter:4}`, `{intent}`,
  `{index}`, `{task}`, `{docdate}` (the date printed on the document, for receipts; the scan date
  otherwise), `{label}` (a document's name, given in the page strip) tokens; automatic
  collision-free numbering.
- **Demo Scanner**: a built-in simulated device so you can try every feature (including OCR,
  photo splitting and a document feeder with three two-sided sheets, which it scans one side or
  both; the second sheet's back is blank; for the ID card task a made-up sample card, which it
  turns over after each scan; for the Receipts task two made-up receipts with faded print and a
  date each; for the Separate documents task a stack of seven sheets with two separator sheets in it, patch-code
  sheets or, split at QR codes or barcodes, Code 39 sheets saying "CS-SEP INVOICE 1002" and naming
  the documents after them) with no
  hardware connected.

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
     when done. Turn on *Searchable PDF* for selectable text.
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
  toolkit (`RgbaImage`, `GrayImage`, `BackgroundMap`, `MaskOps`, `BlankPageDetector`), and the ID
  card's detector, layout and page (`IdCard`)
- `Sources/CompleteScannerKit/Output` — PDF builder, OCR, image export, naming templates
- `Sources/CompleteScannerKit/UI` — SwiftUI views
- `Tests/CompleteScannerTests` — unit tests (synthetic-image based)
