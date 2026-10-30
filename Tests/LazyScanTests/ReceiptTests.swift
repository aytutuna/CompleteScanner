import CoreGraphics
import XCTest
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/ReceiptTests.cs: the same cases, on the same synthetic
// beds (TestPages.receiptBed) and the same date table (ReceiptDateCases).

private let ink: UInt8 = 153     // faded thermal print, 0.6
private let paper = 237          // thermal paper, 0.93
private let lid = 245            // a white lid, 0.96

private func leftReceipt(paper paperValue: Int = paper) -> TestPages.Placed {
    TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: paperValue, ink: ink, lines: 40, seed: 0xC0FF_EE01),
                     centerX: 220, centerY: 585, turn: TestPages.plus3)
}

private func rightReceipt(paper paperValue: Int = paper) -> TestPages.Placed {
    TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: paperValue, ink: ink, lines: 40, seed: 0xC0FF_EE02),
                     centerX: 630, centerY: 585, turn: TestPages.minus3)
}

/// Every print pixel of the receipt lies inside the region.
private func assertCoversPrint(_ region: DetectedPhotoRegion, _ receipt: TestPages.Placed, scale: Double = 1,
                               file: StaticString = #filePath, line: UInt = #line) {
    let a = region.angleDegrees * .pi / 180
    let c = cos(a), s = sin(a)
    var outside = 0
    for p in TestPages.printOnBed(receipt, ink: ink) {
        let dx = Double(p.x) * scale - Double(region.center.x), dy = Double(p.y) * scale - Double(region.center.y)
        let u = dx * c + dy * s, v = -dx * s + dy * c
        if abs(u) > Double(region.size.width) / 2 || abs(v) > Double(region.size.height) / 2 { outside += 1 }
    }
    XCTAssertEqual(outside, 0, file: file, line: line)
}

private let today = DocumentDate(year: 2026, month: 10, day: 19)

private func find(_ text: String, dayFirst: Bool) -> String? {
    ReceiptDateExtractor.findDate(text.components(separatedBy: "\n"), today: today, preferDayFirst: dayFirst)?.text
}

final class ReceiptTests: XCTestCase {

    func test_fixtures_areTheSameOnBothPlatforms() {
        let bed = TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0001, [leftReceipt(), rightReceipt()])
        XCTAssertEqual(bed.pixels.count, TestPages.bedWidth * TestPages.bedHeight)
        XCTAssertEqual(TestPages.checksum(bed), 0xF91D_277D)
    }

    func test_twoReceipts_onAWhiteLid_areFoundApart_eachHoldingAllItsPrint() {
        let left = leftReceipt(), right = rightReceipt()
        let bed = TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0001, [left, right])
        let found = ReceiptDetector.find(bed)
        XCTAssertEqual(found.count, 2)
        guard found.count == 2 else { return }
        // Left to right, as photos are sorted.
        XCTAssertLessThan(found[0].region.center.x, found[1].region.center.x)
        assertCoversPrint(found[0].region, left)
        assertCoversPrint(found[1].region, right)
        XCTAssertEqual(found[0].region.angleDegrees, 3, accuracy: 1)
        XCTAssertEqual(found[1].region.angleDegrees, -3, accuracy: 1)
        // Paper three levels darker than the lid still shows: each is cut along its own edges.
        for receipt in found {
            XCTAssertEqual(receipt.basis, .paper)
            let shortSide = Double(min(receipt.region.size.width, receipt.region.size.height))
            let longSide = Double(max(receipt.region.size.width, receipt.region.size.height))
            XCTAssertTrue((296...306).contains(shortSide), "\(shortSide)")
            XCTAssertTrue((796...806).contains(longSide), "\(longSide)")
        }
    }

    func test_paperAsLightAsTheLid_isCutAroundItsPrint() {
        let left = leftReceipt(paper: lid), right = rightReceipt(paper: lid)
        let bed = TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0002, [left, right])
        let found = ReceiptDetector.find(bed)
        XCTAssertEqual(found.count, 2)
        guard found.count == 2 else { return }
        assertCoversPrint(found[0].region, left)
        assertCoversPrint(found[1].region, right)
        XCTAssertTrue(found.allSatisfy { $0.basis == .text })
        XCTAssertEqual(found[0].region.angleDegrees, 3, accuracy: 1)
        XCTAssertEqual(found[1].region.angleDegrees, -3, accuracy: 1)
        // Tight: the print (0.2 in in from the paper's sides) plus the margin, not the whole paper.
        for receipt in found {
            let width = Double(min(receipt.region.size.width, receipt.region.size.height))
            XCTAssertTrue((260...290).contains(width), "\(width)")
        }
    }

    func test_aLongReceipt_isTooLongForAPage_butNotForAReceipt() {
        // 2 × 11 in on a darker lid: 5.5 times as long as wide.
        let receipt = TestPages.Placed(sheet: TestPages.receipt(200, 1100, paper: 240, ink: ink, lines: 58, seed: 0xC0FF_EE03),
                                       centerX: 425, centerY: 585, turn: TestPages.straight)
        let bed = TestPages.receiptBed(backdrop: 200, seed: 0xBED0_0003, [receipt])
        XCTAssertEqual(DocumentGeometry.findPage(bed).rejection, PageRejection.notRectangular)
        XCTAssertEqual(DocumentGeometry.findPage(bed, options: ReceiptDetector.pageSearch).rejection, PageRejection.none)

        let found = ReceiptDetector.find(bed)
        XCTAssertEqual(found.count, 1)
        guard let only = found.first else { return }
        XCTAssertEqual(only.basis, .paper)
        assertCoversPrint(only.region, receipt)
        let shortSide = Double(min(only.region.size.width, only.region.size.height))
        let longSide = Double(max(only.region.size.width, only.region.size.height))
        XCTAssertTrue((196...206).contains(shortSide), "\(shortSide)")
        XCTAssertTrue((1096...1106).contains(longSide), "\(longSide)")
    }

    func test_defaultPageSearchOptions_areTheConstants() throws {
        let sheet = TestPages.sheetOnBackdrop(TestPages.plus3, backdrop: 120, paper: 245, shadow: 0, seed: 0x5EE7_0001)
        let page = try XCTUnwrap(DocumentGeometry.findPage(sheet).page)
        let same = try XCTUnwrap(DocumentGeometry.findPage(sheet, options: .default).page)
        XCTAssertEqual(page.center, same.center)
        XCTAssertEqual(page.size, same.size)
        XCTAssertEqual(page.angleDegrees, same.angleDegrees)
        XCTAssertEqual(PageSearchOptions.default.pageContrast, DocumentGeometry.pageContrast)
        XCTAssertEqual(PageSearchOptions.default.maxPageAspect, DocumentGeometry.maxPageAspect)
        XCTAssertEqual(PageSearchOptions.default.minPageFill, DocumentGeometry.minPageFill)
        XCTAssertEqual(ReceiptDetector.pageSearch.pageContrast, 0.02)
        XCTAssertEqual(ReceiptDetector.pageSearch.minPageFill, 0.85)
        XCTAssertEqual(ReceiptDetector.pageSearch.maxPageAspect, 15)
    }

    func test_pricesFarFromTheItems_stayOnTheirReceipt() {
        // The prices stand 1.2 in after the longest item: their column is a block of its own.
        let receipt = TestPages.Placed(sheet: TestPages.receipt(300, 700, paper: lid, ink: ink, lines: 30, seed: 0xC0FF_EE04,
                                                                priceGap: 120),
                                       centerX: 300, centerY: 500, turn: TestPages.straight)
        let bed = TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0004, [receipt])
        let found = ReceiptDetector.find(bed)
        XCTAssertEqual(found.count, 1)
        if let only = found.first { assertCoversPrint(only.region, receipt) }
    }

    func test_receiptsCloseTogether_stayApart_whenTheirPaperShows() {
        // 0.15 in apart side by side: the left one's prices are nearer the right one's items than its own.
        let left = TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: paper, ink: ink, lines: 40, seed: 0xC0FF_EE08),
                                    centerX: 270, centerY: 585, turn: TestPages.straight)
        let right = TestPages.Placed(sheet: TestPages.receipt(300, 800, paper: paper, ink: ink, lines: 40, seed: 0xC0FF_EE09),
                                     centerX: 585, centerY: 585, turn: TestPages.straight)
        let bed = TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0008, [left, right])
        let found = ReceiptDetector.find(bed)
        XCTAssertEqual(found.count, 2)
        guard found.count == 2 else { return }
        assertCoversPrint(found[0].region, left)
        assertCoversPrint(found[1].region, right)
    }

    func test_oneReceiptPerScan_takesEverythingPrinted() {
        // Two blocks of print 1.5 in apart: two receipts on the glass, one from the feeder.
        let top = TestPages.Placed(sheet: TestPages.receipt(300, 300, paper: lid, ink: ink, lines: 14, seed: 0xC0FF_EE05),
                                   centerX: 300, centerY: 250, turn: TestPages.straight)
        let bottom = TestPages.Placed(sheet: TestPages.receipt(300, 300, paper: lid, ink: ink, lines: 14, seed: 0xC0FF_EE06),
                                      centerX: 300, centerY: 700, turn: TestPages.straight)
        let bed = TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0005, [top, bottom])
        XCTAssertEqual(ReceiptDetector.find(bed).count, 2)
        let one = ReceiptDetector.find(bed, options: ReceiptDetectorOptions(singleReceipt: true))
        XCTAssertEqual(one.count, 1)
        if let only = one.first {
            assertCoversPrint(only.region, top)
            assertCoversPrint(only.region, bottom)
        }
        XCTAssertEqual(ReceiptDetector.find(bed, options: ReceiptDetectorOptions(maxReceipts: 1)).count, 1)
    }

    func test_nothingOnTheGlass_findsNoReceipt() {
        XCTAssertTrue(ReceiptDetector.find(TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0006, [])).isEmpty)
        // Dust and a scrap too small to be a receipt.
        let scrap = TestPages.Placed(sheet: TestPages.receipt(80, 60, paper: paper, ink: ink, lines: 2, seed: 0xC0FF_EE07),
                                     centerX: 400, centerY: 400, turn: TestPages.straight)
        XCTAssertTrue(ReceiptDetector.find(TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0007, [scrap])).isEmpty)
    }

    func test_fullResolutionScan_givesTheSameReceipts() throws {
        let left = leftReceipt(), right = rightReceipt()
        let bed = TestPages.receiptBed(backdrop: lid, seed: 0xBED0_0001, [left, right])
        let scan = TestPages.enlarged(bed, 3)
        let regions = ReceiptDetector.detectRegions(in: scan, dpi: 300)
        XCTAssertEqual(regions.count, 2)
        guard regions.count == 2 else { return }
        assertCoversPrint(regions[0], left, scale: 3)
        assertCoversPrint(regions[1], right, scale: 3)
        let analysis = ReceiptDetector.find(bed)
        for i in 0..<2 {
            XCTAssertEqual(Double(regions[i].center.x), Double(analysis[i].region.center.x) * 3, accuracy: 9)
            XCTAssertEqual(Double(regions[i].center.y), Double(analysis[i].region.center.y) * 3, accuracy: 9)
        }
        // Cut out and cleaned up: upright, gray, about 3 × 8 in.
        let receipt = try XCTUnwrap(ReceiptDetector.extractEnhanced(scan, region: regions[0], dpi: 300))
        XCTAssertTrue((880...930).contains(receipt.width), "\(receipt.width)")
        XCTAssertTrue((2380...2430).contains(receipt.height), "\(receipt.height)")
    }

    // MARK: Enhancer

    /// A 3 × 4 in receipt at 100 dpi: paper darkening from 0.95 at the top to 0.80 at the bottom, with print at 0.62.
    private func fadedReceipt() -> (image: RgbaImage, print: [Bool]) {
        let w = 300, h = 400
        var gray = [UInt8](repeating: 0, count: w * h)
        var print = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let paperValue = UInt8((242 * (h - 1 - y) + 204 * y) / (h - 1))
            for x in 0..<w { gray[y * w + x] = paperValue }
        }
        let rng = TestPages.Rng(0xFADE_0001)
        for line in 0..<20 {
            let y = 20 + line * 18
            var x = 20
            while x < w - 40 {
                let length = 5 + rng.below(30)
                for py in y..<(y + 6) {
                    for px in x..<min(w - 20, x + length) {
                        gray[py * w + px] = 158
                        print[py * w + px] = true
                    }
                }
                x += length + 8 + rng.below(10)
            }
        }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<gray.count {
            rgba[i * 4] = gray[i]
            rgba[i * 4 + 1] = gray[i]
            rgba[i * 4 + 2] = gray[i]
        }
        return (RgbaImage(width: w, height: h, pixels: rgba), print)
    }

    func test_enhancer_whitensFadingPaper_andDarkensFadedPrint() {
        let (image, print) = fadedReceipt()
        let enhanced = ReceiptEnhancer.enhance(image, dpi: 100)
        XCTAssertEqual(enhanced.width, image.width)
        XCTAssertEqual(enhanced.height, image.height)
        var paperMin = 255, printMax = 0
        for i in 0..<print.count {
            let r = enhanced.pixels[i * 4], g = enhanced.pixels[i * 4 + 1], b = enhanced.pixels[i * 4 + 2]
            XCTAssertTrue(r == g && g == b)
            XCTAssertEqual(enhanced.pixels[i * 4 + 3], 255)
            if print[i] { printMax = max(printMax, Int(r)) } else { paperMin = min(paperMin, Int(r)) }
        }
        XCTAssertGreaterThanOrEqual(paperMin, 242)   // ≥ 0.95
        XCTAssertLessThanOrEqual(printMax, 153)      // ≤ 0.60
    }

    func test_enhancer_keepsALittlePrintFromTurningGray() {
        // One short line on a whole receipt: under 1 % of the pixels, so the darkest print is capped.
        let w = 300, h = 400
        var image = RgbaImage.filled(width: w, height: h, r: 236, g: 236, b: 236)
        for y in 200..<206 {
            for x in 40..<140 {
                let i = (y * w + x) * 4
                image.pixels[i] = 150
                image.pixels[i + 1] = 150
                image.pixels[i + 2] = 150
            }
        }
        let enhanced = ReceiptEnhancer.enhance(image, dpi: 100)
        XCTAssertEqual(enhanced.pixels[(10 * w + 10) * 4], 255)
        XCTAssertLessThanOrEqual(enhanced.pixels[(203 * w + 90) * 4], 40)
    }

    func test_enhancer_leavesADarkLogoDark() {
        // A solid 1 in black block: its tiles' paper is the floor below the middle tile, not the block.
        let w = 300, h = 400
        var image = RgbaImage.filled(width: w, height: h, r: 236, g: 236, b: 236)
        for y in 50..<150 {
            for x in 100..<200 {
                let i = (y * w + x) * 4
                image.pixels[i] = 30
                image.pixels[i + 1] = 30
                image.pixels[i + 2] = 30
            }
        }
        let enhanced = ReceiptEnhancer.enhance(image, dpi: 100)
        XCTAssertLessThanOrEqual(enhanced.pixels[(100 * w + 150) * 4], 20)
        XCTAssertEqual(enhanced.pixels[(300 * w + 150) * 4], 255)
    }

    // MARK: Dates

    func test_dates_thePlanCases() {
        XCTAssertEqual(find("12/03/2025", dayFirst: true), "2025-03-12")
        XCTAssertEqual(find("12/03/2025", dayFirst: false), "2025-12-03")
        XCTAssertEqual(find("31/12/25", dayFirst: false), "2025-12-31")
        XCTAssertEqual(find("2026-01-05", dayFirst: true), "2026-01-05")
        XCTAssertEqual(find("Jan 5, 2026", dayFirst: true), "2026-01-05")
        XCTAssertNil(find("12/03/2030", dayFirst: true))
        XCTAssertNil(find("12:30", dayFirst: true))
        XCTAssertNil(find("Tel 12.34.56", dayFirst: true))
    }

    func test_dates_rangeIsTenYearsBackToTomorrow() {
        XCTAssertEqual(find("20.10.2026", dayFirst: true), "2026-10-20")
        XCTAssertNil(find("21.10.2026", dayFirst: true))
        XCTAssertEqual(find("19.10.2016", dayFirst: true), "2016-10-19")
        XCTAssertNil(find("18.10.2016", dayFirst: true))
        XCTAssertNil(find("29.02.2026", dayFirst: true))
        XCTAssertEqual(find("29.02.2024", dayFirst: true), "2024-02-29")
    }

    func test_dates_dateLinesWin_validityLinesDoNot() {
        XCTAssertEqual(find("Printed 01.09.2026\nTarih: 14.09.2026", dayFirst: true), "2026-09-14")
        XCTAssertEqual(find("Valid until 2026-10-18\n2026-10-02 18:03", dayFirst: true), "2026-10-02")
        XCTAssertNil(find("EXP 10/03/2026", dayFirst: false))
    }

    func test_dates_aWordThatIsNotAMonthDoesNotHideTheDate() {
        // "4 sat 18" reads like a day, a month name and a year; it must not use up the "18" of the date.
        XCTAssertEqual(find("TABLE 4 SAT 18 APR 2026 10:41", dayFirst: false), "2026-04-18")
        XCTAssertEqual(find("Reg 3 Fri 12 Mar 2026", dayFirst: true), "2026-03-12")
        XCTAssertEqual(find("Till 2 Sun Mar 15, 2026", dayFirst: false), "2026-03-15")
        XCTAssertEqual(ReceiptDateExtractor.datesIn("table 4 sat 18 apr 2026 10:41", preferDayFirst: false),
                       [DocumentDate(year: 2026, month: 4, day: 18)])
        // The patterns take every month name, the longest first, and nothing else.
        let names = ReceiptDateExtractor.monthAlternation.components(separatedBy: "|")
        XCTAssertEqual(names.sorted(), ReceiptDateExtractor.monthNames.keys.sorted())
        XCTAssertEqual(names.map(\.count), names.map(\.count).sorted(by: >))
    }

    func test_dates_accuracyOnTheTestSet() {
        var misses: [String] = []
        var total = 0
        for c in ReceiptDateCases.all {
            total += 1
            let got = ReceiptDateExtractor.findDate(c.lines, today: today, preferDayFirst: c.dayFirst)?.text
            if got != c.expected {
                misses.append("\(c.category): \(c.lines.joined(separator: " | ")) -> \(got ?? "none") (expected \(c.expected ?? "none"))")
            }
        }
        // Every case of the set is read as a person reads it, except the known misses of OCR noise.
        XCTAssertEqual(misses.count, ReceiptDateCases.knownMisses, misses.joined(separator: "\n"))
        XCTAssertTrue(misses.allSatisfy { $0.hasPrefix("OCR noise") }, misses.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(total, 90)
    }

    func test_fold_lowersAndDropsAccents() {
        XCTAssertEqual(ReceiptDateExtractor.fold("TARİH 12 Mart 2026 Perşembe"), "tarih 12 mart 2026 persembe")
        XCTAssertEqual(ReceiptDateExtractor.fold("12. März 2026"), "12. marz 2026")
        XCTAssertEqual(ReceiptDateExtractor.fold("1 février août Eylül Aralık"), "1 fevrier aout eylul aralik")
        XCTAssertEqual(ReceiptDateExtractor.fold("12\u{00A0}Mai"), "12 mai")
        XCTAssertEqual(ReceiptDateExtractor.fold("2026年3月12日"), "2026年3月12日")
    }

    func test_prefersDayFirst_fromTheShortDatePattern() {
        XCTAssertTrue(ReceiptDateExtractor.prefersDayFirst("dd.MM.yyyy"))
        XCTAssertTrue(ReceiptDateExtractor.prefersDayFirst("d/M/yyyy"))
        XCTAssertFalse(ReceiptDateExtractor.prefersDayFirst("M/d/yyyy"))
        XCTAssertFalse(ReceiptDateExtractor.prefersDayFirst("yyyy-MM-dd"))
        XCTAssertFalse(ReceiptDateExtractor.prefersDayFirst(""))
    }

    // MARK: DocumentDate

    func test_documentDate_calendar() {
        XCTAssertTrue(DocumentDate.isValid(year: 2024, month: 2, day: 29))
        XCTAssertFalse(DocumentDate.isValid(year: 2025, month: 2, day: 29))
        XCTAssertFalse(DocumentDate.isValid(year: 1900, month: 2, day: 29))
        XCTAssertTrue(DocumentDate.isValid(year: 2000, month: 2, day: 29))
        XCTAssertFalse(DocumentDate.isValid(year: 2026, month: 4, day: 31))
        XCTAssertFalse(DocumentDate.isValid(year: 2026, month: 13, day: 1))
        XCTAssertFalse(DocumentDate.isValid(year: 2026, month: 0, day: 1))
        XCTAssertNil(DocumentDate.make(year: 2026, month: 6, day: 31))
        XCTAssertEqual(DocumentDate(year: 1970, month: 1, day: 1).dayNumber, 0)
        XCTAssertEqual(DocumentDate(year: 2026, month: 4, day: 1).dayNumber, 20544)
        XCTAssertEqual(DocumentDate(year: 2026, month: 3, day: 1).dayNumber - DocumentDate(year: 2026, month: 2, day: 28).dayNumber, 1)
        XCTAssertEqual(DocumentDate(year: 2024, month: 2, day: 29).addingYears(-1), DocumentDate(year: 2023, month: 2, day: 28))
        XCTAssertEqual(DocumentDate(year: 2026, month: 3, day: 5).text, "2026-03-05")
        XCTAssertLessThan(DocumentDate(year: 2026, month: 3, day: 5), DocumentDate(year: 2026, month: 3, day: 6))
        XCTAssertLessThan(DocumentDate(year: 2025, month: 12, day: 31), DocumentDate(year: 2026, month: 1, day: 1))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 59))!
        XCTAssertEqual(DocumentDate(date: lateEvening), DocumentDate(year: 2026, month: 10, day: 19))
    }

    // MARK: What the task shows

    func test_receipts_titlesAndMessages() {
        XCTAssertEqual(Receipts.reviewTitle(4), "Found 4 receipts")
        XCTAssertEqual(Receipts.reviewTitle(1), "Found 1 receipt")
        XCTAssertEqual(Receipts.saveTitle(included: 3, combine: false, format: .pdf), "Save 3 Receipts")
        XCTAssertEqual(Receipts.saveTitle(included: 1, combine: true, format: .pdf), "Save 1 Receipt")
        XCTAssertEqual(Receipts.saveTitle(included: 3, combine: true, format: .pdf), "Save as One PDF")
        XCTAssertEqual(Receipts.saveTitle(included: 3, combine: true, format: .word), "Save as One PDF")
        XCTAssertEqual(Receipts.saveTitle(included: 3, combine: true, format: .jpeg), "Save 3 Receipts")
        XCTAssertEqual(Receipts.savedMessage(count: 2, fileNames: ["a.pdf", "b.pdf"], combined: false, undated: 0),
                       "Saved 2 receipts: a.pdf, b.pdf")
        XCTAssertEqual(Receipts.savedMessage(count: 3, fileNames: ["a.pdf"], combined: true, undated: 0),
                       "Saved 3 receipts in one PDF: a.pdf")
        XCTAssertEqual(Receipts.savedMessage(count: 1, fileNames: ["a.pdf"], combined: false, undated: 1),
                       "Saved 1 receipt: a.pdf. No date was found on it; it is named by today's date.")
        XCTAssertEqual(Receipts.savedMessage(count: 3, fileNames: ["a", "b", "c"], combined: false, undated: 1),
                       "Saved 3 receipts: a, b, c. No date was found on 1 of them; it is named by today's date.")
        XCTAssertEqual(Receipts.savedMessage(count: 3, fileNames: ["a", "b", "c"], combined: false, undated: 2),
                       "Saved 3 receipts: a, b, c. No date was found on 2 of them; they are named by today's date.")
        XCTAssertEqual(Receipts.savedMessage(count: 2, fileNames: ["a", "b"], combined: false, undated: 2),
                       "Saved 2 receipts: a, b. No date was found on them; they are named by today's date.")
        // One PDF is named by the earliest date found: by today's only when no receipt had a date.
        XCTAssertEqual(Receipts.savedMessage(count: 3, fileNames: ["a.pdf"], combined: true, undated: 1),
                       "Saved 3 receipts in one PDF: a.pdf")
        XCTAssertEqual(Receipts.savedMessage(count: 3, fileNames: ["a.pdf"], combined: true, undated: 2),
                       "Saved 3 receipts in one PDF: a.pdf")
        XCTAssertEqual(Receipts.savedMessage(count: 3, fileNames: ["a.pdf"], combined: true, undated: 3),
                       "Saved 3 receipts in one PDF: a.pdf. No date was found on them; the PDF is named by today's date.")
    }

    func test_receipts_combinedDateIsTheEarliest() {
        XCTAssertEqual(Receipts.combinedDate([DocumentDate(year: 2026, month: 3, day: 15), nil, DocumentDate(year: 2026, month: 3, day: 2)]),
                       DocumentDate(year: 2026, month: 3, day: 2))
        XCTAssertNil(Receipts.combinedDate([nil, nil]))
        XCTAssertNil(Receipts.combinedDate([]))
    }

    func test_receipts_readTextForTheDateOrTheTextLayer() {
        var s = TaskCatalog.apply(.receipt, to: ScanSettings())
        XCTAssertTrue(Receipts.readsText(s))
        s.taskOptions.receiptNameByDate = false
        XCTAssertTrue(Receipts.readsText(s))
        s.pdfSearchable = false
        XCTAssertFalse(Receipts.readsText(s))
        s.output.alsoSaveText = true
        XCTAssertTrue(Receipts.readsText(s))
        s.format = .jpeg
        XCTAssertFalse(Receipts.readsText(s))
    }

    func test_receipts_namedByDateOnlyWhenTheTemplateHasDocDate() {
        var s = TaskCatalog.apply(.receipt, to: ScanSettings())
        s.format = .jpeg
        XCTAssertTrue(Receipts.namesByDate(s))
        XCTAssertTrue(Receipts.readsText(s))
        // Without {docdate} the date goes nowhere: it is not read for the name.
        s.namingTemplate = "Expenses {date} {counter}"
        XCTAssertFalse(Receipts.namesByDate(s))
        XCTAssertFalse(Receipts.readsText(s))
        s.namingTemplate = "Expenses {DOCDATE} {counter}"
        XCTAssertFalse(Receipts.namesByDate(s))
        s.namingTemplate = "{docdate}"
        XCTAssertTrue(Receipts.namesByDate(s))
        s.taskOptions.receiptNameByDate = false
        XCTAssertFalse(Receipts.namesByDate(s))
    }

    func test_receipts_textLinesAreInReadingOrder() {
        // Bottom-left origin: the higher line comes first.
        let lines = [
            OCRLine(text: "TOTAL 4.20", boundingBox: CGRect(x: 0.1, y: 0.10, width: 0.6, height: 0.03), confidence: 1),
            OCRLine(text: "DEMO CAFE", boundingBox: CGRect(x: 0.3, y: 0.90, width: 0.4, height: 0.04), confidence: 1),
            OCRLine(text: "Date 12/03/2026", boundingBox: CGRect(x: 0.1, y: 0.80, width: 0.6, height: 0.03), confidence: 1),
        ]
        XCTAssertEqual(Receipts.textLines(lines, pixelWidth: 900, pixelHeight: 2400), ["DEMO CAFE", "Date 12/03/2026", "TOTAL 4.20"])
    }
}

/// The date test set: receipt text as OCR returns it, with the date a person reads on it. Mirrored by the
/// C# `ReceiptDateCases`. Merchants are made up.
enum ReceiptDateCases {
    struct Case {
        let category: String
        let lines: [String]
        let dayFirst: Bool
        let expected: String?
    }

    private static func c(_ category: String, _ text: String, _ dayFirst: Bool, _ expected: String?) -> Case {
        Case(category: category, lines: text.components(separatedBy: "\n"), dayFirst: dayFirst, expected: expected)
    }

    /// OCR noise the extractor does not repair: letters read for digits, spaces inside a date.
    static let knownMisses = 3

    static let all: [Case] = [
        // ISO and year-first.
        c("ISO", "2026-03-12", false, "2026-03-12"),
        c("ISO", "Date: 2026/03/12 14:22", false, "2026-03-12"),
        c("ISO", "2026.03.12", true, "2026-03-12"),
        c("ISO", "2026-3-5", false, "2026-03-05"),
        c("ISO", "DATE 2025-12-31 23:59", true, "2025-12-31"),
        c("ISO", "Bon 0042 2026-10-19T08:15", true, "2026-10-19"),
        c("ISO", "Order 2026-0012", true, nil),
        // United States: month first.
        c("US", "03/12/2026", false, "2026-03-12"),
        c("US", "12/31/2025", false, "2025-12-31"),
        c("US", "1/5/26", false, "2026-01-05"),
        c("US", "Date: 10/01/2026 08:15 PM", false, "2026-10-01"),
        c("US", "Trans 4471 07-04-2026", false, "2026-07-04"),
        c("US", "SALE 09/30/26 11:02", false, "2026-09-30"),
        c("US", "Store 0815 Reg 3 Date 6/7/2026", false, "2026-06-07"),
        c("US", "Cashier: Pat 08/15/2026", false, "2026-08-15"),
        // Europe: day first.
        c("EU", "12/03/2026", true, "2026-03-12"),
        c("EU", "31/12/25", true, "2025-12-31"),
        c("EU", "05-01-2026", true, "2026-01-05"),
        c("EU", "Datum: 12.03.2026", true, "2026-03-12"),
        c("EU", "Fecha: 07/08/2026 13:45", true, "2026-08-07"),
        c("EU", "Le 15/09/2026 à 10:12", true, "2026-09-15"),
        c("EU", "Data 3.9.2026", true, "2026-09-03"),
        c("EU", "13/05/2026", false, "2026-05-13"),
        c("EU", "12. 03. 2026", true, "2026-03-12"),
        // Turkish: day first with dots.
        c("Turkish", "Tarih: 12.03.2026 Saat: 14:35", false, "2026-03-12"),
        c("Turkish", "TARİH : 05.01.2026", true, "2026-01-05"),
        c("Turkish", "12.03.26", true, "2026-03-12"),
        c("Turkish", "FİŞ TARİHİ: 30.09.2026", true, "2026-09-30"),
        c("Turkish", "Düzenleme tarihi 01.10.2026", true, "2026-10-01"),
        c("Turkish", "14/09/2026 SAAT 19:20", true, "2026-09-14"),
        c("Turkish", "12 Mart 2026", true, "2026-03-12"),
        c("Turkish", "5 Ağustos 2025 Salı", true, "2025-08-05"),
        c("Turkish", "01 OCAK 2026", true, "2026-01-01"),
        c("Turkish", "28 Şubat 2026 Cumartesi", true, "2026-02-28"),
        c("Turkish", "3 Eylül 2026", true, "2026-09-03"),
        c("Turkish", "19 Ekim 2026", true, "2026-10-19"),
        c("Turkish", "9 Kasım 2025", true, "2025-11-09"),
        c("Turkish", "31 Aralık 2025", true, "2025-12-31"),
        c("Turkish", "7 Haziran 2026", true, "2026-06-07"),
        c("Turkish", "15 Mayıs 2026", true, "2026-05-15"),
        // English month names.
        c("Month names", "12 Mar 2026", false, "2026-03-12"),
        c("Month names", "Mar 12, 2026", true, "2026-03-12"),
        c("Month names", "March 12th, 2026", true, "2026-03-12"),
        c("Month names", "12-MAR-26", false, "2026-03-12"),
        c("Month names", "Jan 5,2026", true, "2026-01-05"),
        c("Month names", "5 January 2026", false, "2026-01-05"),
        c("Month names", "Sept 9, 2025", true, "2025-09-09"),
        c("Month names", "Dec. 3 2025", true, "2025-12-03"),
        c("Month names", "1st February 2026", false, "2026-02-01"),
        c("Month names", "SAT 18 APR 2026 10:41", false, "2026-04-18"),
        c("Month names", "TABLE 4 SAT 18 APR 2026 10:41", false, "2026-04-18"),
        c("Month names", "Reg 3 Fri 12 Mar 2026", true, "2026-03-12"),
        c("Month names", "18-OCT-26 07:55", false, "2026-10-18"),
        c("Month names", "Thursday, October 1, 2026", false, "2026-10-01"),
        // Other languages.
        c("Month names", "12. März 2026", true, "2026-03-12"),
        c("Month names", "12 mars 2026", true, "2026-03-12"),
        c("Month names", "12 de marzo de 2026", true, "2026-03-12"),
        c("Month names", "3 giugno 2026", true, "2026-06-03"),
        c("Month names", "12 maart 2026", true, "2026-03-12"),
        c("Month names", "1 février 2026", true, "2026-02-01"),
        c("Month names", "15 dezembro 2025", true, "2025-12-15"),
        c("Month names", "2 août 2026", true, "2026-08-02"),
        c("Month names", "21 Okt. 2025", true, "2025-10-21"),
        // Chinese, Japanese, Korean.
        c("CJK", "2026年3月12日", false, "2026-03-12"),
        c("CJK", "2026 年 10 月 1 日 14:20", false, "2026-10-01"),
        c("CJK", "2026년 3월 12일", false, "2026-03-12"),
        // Day or month: a part above 12 decides, dots put the day first, otherwise the region.
        c("Ambiguous", "03/04/2026", true, "2026-04-03"),
        c("Ambiguous", "03/04/2026", false, "2026-03-04"),
        c("Ambiguous", "03.04.2026", false, "2026-04-03"),
        c("Ambiguous", "04/25/2026", true, "2026-04-25"),
        // Not dates.
        c("Not a date", "12:30", true, nil),
        c("Not a date", "Tel 12.34.56", true, nil),
        c("Not a date", "Total 12.50", true, nil),
        c("Not a date", "Card **** 1234", true, nil),
        c("Not a date", "EXP 12/28", true, nil),
        c("Not a date", "31/02/2026", true, nil),
        c("Not a date", "12/03/2030", true, nil),
        c("Not a date", "12/03/2010", true, nil),
        c("Not a date", "Qty 2 x 3.50", true, nil),
        c("Not a date", "1 SET 25.00", true, nil),
        c("Not a date", "IP 192.168.1.10", true, nil),
        c("Not a date", "Ref 20260312", true, nil),
        c("Not a date", "Phone 0212 555 12 34", true, nil),
        c("Not a date", "Mar 12", true, nil),
        // Whole receipts: the date among times, phone numbers, amounts and expiry dates.
        c("Receipts", "DEMO CAFE\n123 Example St\nTel 555-0100\n12:41 Table 4\nLatte 3.50\nTOTAL 3.50\nVISA **** 4242 EXP 09/28\nDate 03/12/2026", false, "2026-03-12"),
        c("Receipts", "TEST MARKET A.Ş.\nVKN 1234567890\nTARİH: 14.09.2026\nSAAT: 19:20\nFİŞ NO: 0042\nTOPLAM *45,90", true, "2026-09-14"),
        c("Receipts", "SAMPLE MART\nReturns accepted until 2026-12-31\n2026-10-02 18:03\nBREAD 2.10", true, "2026-10-02"),
        c("Receipts", "FICTIONAL FUEL CO\nPump 3 Unleaded\n18-OCT-26 07:55\n40.12 L @ 1.799\nTOTAL 72.18", false, "2026-10-18"),
        c("Receipts", "DEMO CAFE\nLatte 3.50\nTOTAL 3.50", true, nil),
        c("Receipts", "EXAMPLE BAKERY\n2 x Croissant 2.40\nBest before 25.10.2026\nPrinted 17.10.2026 09:12", true, "2026-10-17"),
        c("Receipts", "MUSTERLADEN GMBH\nBon 1234 Kasse 2\nDatum 12.03.2026 Uhrzeit 10:15\nGültig bis 12.04.2026", true, "2026-03-12"),
        c("Receipts", "PLACEHOLDER PHARMACY\nRx 55120\nFILLED 09/02/2026\nEXPIRES 09/02/2027", false, "2026-09-02"),
        c("Receipts", "SAMPLE TAXI\nFrom 22:10 to 22:41\nFare 18.40\n4 Oct 2026", true, "2026-10-04"),
        c("Receipts", "DEMO HOTEL\nArrival 01/10/2026\nDeparture 04/10/2026\nInvoice date 04/10/2026", true, "2026-10-04"),
        // OCR noise: letters read as digits and spaces inside a date are not repaired.
        c("OCR noise", "2O26-03-12", true, "2026-03-12"),
        c("OCR noise", "12/03/2O26", true, "2026-03-12"),
        c("OCR noise", "12 / 03 / 2026", true, "2026-03-12"),
        c("OCR noise", "Date:12/03/2026", true, "2026-03-12"),
        c("OCR noise", "DATE12.03.2026", true, "2026-03-12"),
    ]
}
