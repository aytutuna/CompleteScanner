import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/OrientationTests.cs: rotate pages upright — what a
// reading scores, which ways up are read, when a page is turned, and what the page strip says about it.

/// `rgba` with a black 20 × 20 px square 10 px in from its top left corner.
private func marked(_ rgba: RgbaImage) -> RgbaImage {
    var page = rgba
    for y in 10..<30 {
        for x in 10..<30 {
            let i = (y * page.width + x) * 4
            page.pixels[i] = 0
            page.pixels[i + 1] = 0
            page.pixels[i + 2] = 0
        }
    }
    return page
}

/// The page of text lines (`TestPages.textPage`) as an RGBA scan at 100 dpi, upright, with a dark
/// square in its top left corner that tells the stand-in OCR which way up it is.
private let textRgba = marked(TestPages.enlarged(TestPages.textPage(), 1))
private let blankRgba = TestPages.enlarged(TestPages.cleanBlank(), 1)

private let readsWell = OrientationScore(letters: 400, wordLetters: 380)
private let upsideDown = OrientationScore(letters: 200, wordLetters: 90)
private let sideways = OrientationScore(letters: 5, wordLetters: 0)

private func page(_ rgba: RgbaImage) -> ScannedPage {
    ScannedPage(image: rgba.makeCGImage()!, dpi: 100, colorMode: .color)
}

private func pixels(_ image: CGImage) -> [UInt8] {
    RgbaImage(cgImage: image)!.pixels
}

/// How far a picture of `textRgba` is turned from upright, in quarter turns clockwise, by the
/// corner its square is in; nil when no corner is dark.
private func turnsFromUpright(_ image: RgbaImage) -> Int? {
    let side = 40
    let w = image.width, h = image.height
    func mean(_ x0: Int, _ y0: Int) -> Double {
        var sum = 0
        for y in y0..<(y0 + side) {
            for x in x0..<(x0 + side) { sum += Int(image.pixels[(y * w + x) * 4]) }
        }
        return Double(sum) / Double(side * side)
    }
    // Turning clockwise takes the top left corner to the top right, the bottom right, the bottom left.
    let corners = [mean(0, 0), mean(w - side, 0), mean(w - side, h - side), mean(0, h - side)]
    var darkest = 0
    for i in 1..<4 where corners[i] < corners[darkest] { darkest = i }
    return corners[darkest] < 200 ? darkest : nil
}

/// A stand-in for text recognition that reads `textRgba` as real OCR reads a letter: well upright,
/// words that are not words upside down, next to nothing sideways. It records how far from upright
/// each picture it was given was turned (clockwise quarter turns).
private final class FakeScorer: OrientationScorer {
    let upright: OrientationScore
    let upsideDown: OrientationScore
    let sideways: OrientationScore
    var isAvailable = true
    var fails = false
    var onScore: (() -> Void)?
    private(set) var seen: [Int] = []

    init(_ upright: OrientationScore, _ upsideDown: OrientationScore, _ sideways: OrientationScore) {
        self.upright = upright
        self.upsideDown = upsideDown
        self.sideways = sideways
    }

    func score(_ image: RgbaImage) throws -> OrientationScore {
        onScore?()
        if fails { throw ScanError.scanFailed("OCR failed: the recognizer stopped.") }
        guard let turns = turnsFromUpright(image) else { return OrientationScore.none }
        seen.append(turns)
        return turns == 0 ? upright : turns == 2 ? upsideDown : sideways
    }
}

private func likeALetter() -> FakeScorer { FakeScorer(readsWell, upsideDown, sideways) }

private func score(_ letters: Int, _ words: Int) -> OrientationScore {
    OrientationScore(letters: letters, wordLetters: words)
}

final class OrientationTests: XCTestCase {

    // MARK: Scores

    func test_score_countsLetters_andTheLettersOfWordsThatLookLikeWords() {
        let result = OrientationScore.of([
            "THE AMERICAN NATIONAL RED CROSS.",
            "August 21, 1903.",
            "sanof RTtnJqoedsea a.10Jaq suo!umqxa",
            "o O 0",
            "Jean-Pierre l'eau don\u{2019}t McKinley",
            "\u{6771}\u{4EAC}\u{90FD} 2nd",
        ])
        XCTAssertEqual(result, score(105, 65))
        XCTAssertEqual(OrientationScore.of([]), OrientationScore.none)
        XCTAssertEqual(OrientationScore.of(["", "   "]), OrientationScore.none)
    }

    func test_wordScore_takesWordsInOneCase_andNumbers() {
        let cases: [(String, Int)] = [
            ("Lieutenant,", 10), ("1903.", 4), ("Jean-Pierre", 10), ("(HARRY)", 5), ("SVNVNVEI", 8),
            ("a-b", 2), ("a.10Jaq", 0), ("RTtnJqoed", 0), ("o", 0), ("--", 0), ("x-", 0), ("2nd", 0), ("", 0),
        ]
        for (word, letters) in cases {
            XCTAssertEqual(OrientationScore.wordScore(word), letters, word)
        }
    }

    func test_readsClearly_needsEnoughWords_andFewLettersOutsideThem() {
        XCTAssertTrue(readsWell.readsClearly)
        XCTAssertTrue(score(150, 150).readsClearly)
        XCTAssertFalse(score(400, 300).readsClearly)
        XCTAssertFalse(score(160, 149).readsClearly)
        XCTAssertFalse(upsideDown.readsClearly)
        XCTAssertFalse(OrientationScore.none.readsClearly)
    }

    // MARK: Which ways up are read

    func test_candidates_followTheLinesOfText() {
        XCTAssertEqual(OrientationDecision.candidates(TextLayout(axis: .horizontal, skewDegrees: 0.5, confidence: 0.6, inkPoints: 5000)), [0, 2])
        XCTAssertEqual(OrientationDecision.candidates(TextLayout(axis: .vertical, skewDegrees: -1, confidence: 0.6, inkPoints: 5000)), [1, 3])
        XCTAssertEqual(OrientationDecision.candidates(TextLayout(axis: .unknown, skewDegrees: 0, confidence: 0.6, inkPoints: 5000)), [0, 2, 1, 3])
        // Lines too faint to trust: every way up.
        XCTAssertEqual(OrientationDecision.candidates(TextLayout(axis: .horizontal, skewDegrees: 0, confidence: 0.1, inkPoints: 5000)), [0, 2, 1, 3])
        // Too little ink to hold text: nothing is read.
        XCTAssertEqual(OrientationDecision.candidates(TextLayout(axis: .horizontal, skewDegrees: 0, confidence: 0.6,
                                                                 inkPoints: DocumentGeometry.minInkPoints - 1)), [])
        XCTAssertEqual(OrientationDecision.candidates(TextLayout.nothing), [])
    }

    func test_choose_needsEnoughWords_andAClearMargin() {
        func c(_ turns: Int, _ words: Int) -> CandidateScore {
            CandidateScore(quarterTurns: turns, score: score(words + 10, words))
        }
        XCTAssertEqual(OrientationDecision.choose([c(0, 100), c(2, 50)]), 0)
        XCTAssertEqual(OrientationDecision.choose([c(0, 49), c(2, 100)]), 2)
        XCTAssertEqual(OrientationDecision.choose([c(1, 0), c(3, 250)]), 3)
        XCTAssertEqual(OrientationDecision.choose([c(0, 3), c(2, 4), c(1, 20), c(3, 10)]), 1)
        XCTAssertEqual(OrientationDecision.choose([c(0, 20)]), 0)
        XCTAssertNil(OrientationDecision.choose([c(0, 100), c(2, 51)]))    // not twice as many
        XCTAssertNil(OrientationDecision.choose([c(0, 19), c(2, 0)]))      // too few
        XCTAssertNil(OrientationDecision.choose([c(0, 80), c(2, 80)]))     // a tie
        XCTAssertNil(OrientationDecision.choose([c(0, 0), c(2, 0), c(1, 0), c(3, 0)]))
        XCTAssertNil(OrientationDecision.choose([]))
    }

    func test_analysisImage_isAtMost1600PixelsLong() {
        func size(_ w: Int, _ h: Int) -> [Int] {
            let s = OrientationDecision.analysisSize(width: w, height: h)
            return [s.width, s.height]
        }
        XCTAssertEqual(size(850, 1100), [850, 1100])
        XCTAssertEqual(size(1600, 1600), [1600, 1600])
        XCTAssertEqual(size(2550, 3300), [1236, 1600])
        XCTAssertEqual(size(3300, 2550), [1600, 1236])
        XCTAssertEqual(size(9000, 2), [1600, 1])
        XCTAssertEqual(OrientationDecision.analysisImage(textRgba), textRgba)
        let wide = OrientationDecision.analysisImage(RgbaImage.filled(width: 2000, height: 100, r: 9, g: 9, b: 9))
        XCTAssertEqual([wide.width, wide.height], [1600, 80])
    }

    // MARK: Reading a page

    func test_check_uprightPage_isLeftAsIs_afterOneReading() throws {
        let scorer = likeALetter()
        let check = try OrientationDecision.check(textRgba, dpi: 100, scorer: scorer)
        XCTAssertEqual(check.verdict, .upright)
        XCTAssertEqual(check.quarterTurns, 0)
        XCTAssertEqual(check.layout.axis, .horizontal)
        XCTAssertEqual(scorer.seen, [0])
        XCTAssertEqual(check.passes, 1)
        XCTAssertEqual(check.scores, [CandidateScore(quarterTurns: 0, score: readsWell)])
    }

    func test_check_pageTurnedAnyWay_isTurnedUpright() throws {
        // (the page's turn from upright, the turn that makes it upright, what was read: turns from upright)
        // A sideways page that reads clearly at the first quarter turn is read the other way too.
        let cases: [(turned: Int, expected: Int, seen: [Int])] = [(2, 2, [2, 0]), (1, 3, [2, 0]), (3, 1, [0, 2])]
        for (turned, expected, seen) in cases {
            let scorer = likeALetter()
            let check = try OrientationDecision.check(textRgba.rotatedQuarterTurns(turned), dpi: 100, scorer: scorer)
            XCTAssertEqual(check.verdict, .turned, "\(turned)")
            XCTAssertEqual(check.quarterTurns, expected, "\(turned)")
            let axis: TextAxis = turned % 2 == 0 ? .horizontal : .vertical
            XCTAssertEqual(check.layout.axis, axis, "\(turned)")
            XCTAssertEqual(scorer.seen, seen, "\(turned)")
        }
    }

    func test_check_noReadingClear_theBestWithAMarginWins() throws {
        // Upright reads 90 letters in words, upside down 40: not clear, but more than twice as many.
        let scorer = FakeScorer(score(100, 90), score(60, 40), sideways)
        let check = try OrientationDecision.check(textRgba.rotatedQuarterTurns(2), dpi: 100, scorer: scorer)
        XCTAssertEqual(check.verdict, .turned)
        XCTAssertEqual(check.quarterTurns, 2)
        XCTAssertEqual(scorer.seen, [2, 0])
        let upright = try OrientationDecision.check(textRgba, dpi: 100, scorer: FakeScorer(score(100, 90), score(60, 40), sideways))
        XCTAssertEqual(upright.verdict, .upright)
        XCTAssertEqual(upright.quarterTurns, 0)
        XCTAssertEqual(upright.passes, 2)
    }

    func test_check_clearReadingTurned_needsAMarginOverTheReadingsBefore() throws {
        // As it is: many words but not clear (prices, dates); upside down: clear, but not twice as many.
        let scorer = FakeScorer(score(200, 140), score(170, 160), sideways)
        let check = try OrientationDecision.check(textRgba, dpi: 100, scorer: scorer)
        XCTAssertEqual(check.verdict, .unsure)
        XCTAssertEqual(check.quarterTurns, 0)
        XCTAssertEqual(check.passes, 2)
        XCTAssertEqual(scorer.seen, [0, 2])
        // Twice as many as the reading before: taken.
        let twice = try OrientationDecision.check(textRgba.rotatedQuarterTurns(2), dpi: 100,
                                                  scorer: FakeScorer(score(300, 280), score(200, 140), sideways))
        XCTAssertEqual(twice.verdict, .turned)
        XCTAssertEqual(twice.quarterTurns, 2)
        XCTAssertEqual(twice.passes, 2)
        // Just under twice as many: left as it is.
        let under = try OrientationDecision.check(textRgba.rotatedQuarterTurns(2), dpi: 100,
                                                  scorer: FakeScorer(score(300, 280), score(200, 141), sideways))
        XCTAssertEqual(under.verdict, .unsure)
        XCTAssertEqual(under.quarterTurns, 0)
        XCTAssertEqual(under.passes, 2)
    }

    func test_check_clearReadingSideways_isNotTakenBeforeTheOppositeWayIsRead() throws {
        // Lines down the page, upright at turn 3: turn 1 shows it upside down and reads clear (like
        // upside-down text read as words), turn 3 reads twice as many words. Both are read; turn 3 wins.
        let sidewaysPage = textRgba.rotatedQuarterTurns(1)
        let scorer = FakeScorer(readsWell, score(170, 160), sideways)
        let check = try OrientationDecision.check(sidewaysPage, dpi: 100, scorer: scorer)
        XCTAssertEqual(check.layout.axis, .vertical)
        XCTAssertEqual(check.verdict, .turned)
        XCTAssertEqual(check.quarterTurns, 3)
        XCTAssertEqual(check.passes, 2)
        XCTAssertEqual(scorer.seen, [2, 0])
        XCTAssertEqual(check.scores.map { $0.quarterTurns }, [1, 3])
        // Turn 3 clear too but not twice as many: neither is taken.
        let close = try OrientationDecision.check(sidewaysPage, dpi: 100,
                                                  scorer: FakeScorer(score(300, 280), score(170, 160), sideways))
        XCTAssertEqual(close.verdict, .unsure)
        XCTAssertEqual(close.quarterTurns, 0)
        XCTAssertEqual(close.passes, 2)
    }

    func test_check_unclearText_isLeftAsIs() throws {
        let scorer = FakeScorer(score(70, 50), score(50, 30), sideways)
        let check = try OrientationDecision.check(textRgba.rotatedQuarterTurns(2), dpi: 100, scorer: scorer)
        XCTAssertEqual(check.verdict, .unsure)
        XCTAssertEqual(check.quarterTurns, 0)
        XCTAssertEqual(check.passes, 2)
        let scanned = page(textRgba.rotatedQuarterTurns(2))
        let after = OrientationStep(scorer: scorer).apply(scanned)
        XCTAssertNil(after.upright)
        XCTAssertTrue(after.image === scanned.image)
    }

    func test_check_pageWithoutText_isNotRead() throws {
        let scorer = likeALetter()
        let check = try OrientationDecision.check(blankRgba, dpi: 100, scorer: scorer)
        XCTAssertEqual(check.verdict, .noText)
        XCTAssertEqual(check.quarterTurns, 0)
        XCTAssertEqual(check.passes, 0)
        XCTAssertEqual(scorer.seen, [])
    }

    func test_check_stopsReadingWhenThePageTakesTooLong() throws {
        var now = 0.0
        let scorer = FakeScorer(score(70, 50), score(50, 30), sideways)
        scorer.onScore = { now += 4 }
        let check = try OrientationDecision.check(textRgba.rotatedQuarterTurns(2), dpi: 100, scorer: scorer,
                                                  maxSeconds: 3, clock: { now })
        XCTAssertEqual(check.verdict, .outOfTime)
        XCTAssertEqual(check.quarterTurns, 0)
        XCTAssertEqual(check.passes, 1)
        XCTAssertEqual(check.seconds, 4)
        // Within the time, both ways are read.
        now = 0
        let slow = FakeScorer(score(70, 50), score(50, 30), sideways)
        slow.onScore = { now += 1 }
        XCTAssertEqual(try OrientationDecision.check(textRgba, dpi: 100, scorer: slow, maxSeconds: 3, clock: { now }).passes, 2)
    }

    func test_check_recognitionFailing_leavesThePage() throws {
        let scorer = likeALetter()
        scorer.fails = true
        let check = try OrientationDecision.check(textRgba.rotatedQuarterTurns(2), dpi: 100, scorer: scorer)
        XCTAssertEqual(check.verdict, .unsure)
        XCTAssertEqual(check.quarterTurns, 0)
        XCTAssertEqual(check.passes, 0)
    }

    func test_check_stopsWhenCancelled() {
        XCTAssertThrowsError(try OrientationDecision.check(textRgba, dpi: 100, scorer: likeALetter(), shouldContinue: { false })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
        // Cancelled during the first reading: the second is not started.
        var cancelled = false
        let scorer = FakeScorer(score(70, 50), upsideDown, sideways)
        scorer.onScore = { cancelled = true }
        XCTAssertThrowsError(try OrientationDecision.check(textRgba, dpi: 100, scorer: scorer, shouldContinue: { !cancelled }))
        XCTAssertEqual(scorer.seen.count, 1)
    }

    // MARK: The step

    func test_step_turnsThePageAndItsOtherVersion_keepingItsFacts() throws {
        let scanned = textRgba.rotatedQuarterTurns(2).makeCGImage()!
        let start = ScannedPage(image: scanned, dpi: 100, colorMode: .color)
            .withSide(.back, sheetIndex: 1)
            .withBlank(BlankPageResult(inkCoverage: 0.02, inkComponents: 300, hasLargeDarkArea: false, isBlank: false))
            .withGeometry(scanned, geometry: PageGeometry(cropped: false, angleDegrees: 1.5, basis: .textLines))
        let turned = OrientationStep(scorer: likeALetter()).apply(start)
        XCTAssertEqual(OrientationStep(scorer: likeALetter()).name, "orientation")
        XCTAssertEqual(turned.id, start.id)
        XCTAssertEqual(turned.upright, UprightTurn(quarterTurns: 2))
        let upright = pixels(ImagePipeline.rotate(scanned, quarterTurns: 2))
        XCTAssertEqual(pixels(turned.image), upright)
        XCTAssertEqual(pixels(try XCTUnwrap(turned.alternate?.image)), upright)
        XCTAssertEqual(turned.rotationQuarterTurns, 0)
        XCTAssertEqual(turned.side, .back)
        XCTAssertEqual(turned.sheetIndex, 1)
        XCTAssertEqual(turned.blank, start.blank)
        XCTAssertEqual(turned.geometry, start.geometry)
        // Upright already: unchanged, nothing recorded.
        let already = page(textRgba)
        let after = OrientationStep(scorer: likeALetter()).apply(already)
        XCTAssertNil(after.upright)
        XCTAssertTrue(after.image === already.image)
    }

    func test_step_doesNotReadBlankPagesOrSeparatorSheets() throws {
        let scorer = likeALetter()
        let step = OrientationStep(scorer: scorer)
        let blank = page(textRgba.rotatedQuarterTurns(2))
            .withBlank(BlankPageResult(inkCoverage: 0.00001, inkComponents: 1, hasLargeDarkArea: false, isBlank: true))
        let separator = page(textRgba.rotatedQuarterTurns(2)).withPatch(.patchT)
        XCTAssertNil(step.apply(blank).upright)
        XCTAssertTrue(step.apply(blank).image === blank.image)
        XCTAssertNil(step.apply(separator).upright)
        XCTAssertEqual(scorer.seen, [])
        // A page checked and found not blank is read.
        let printed = page(textRgba.rotatedQuarterTurns(2))
            .withBlank(BlankPageResult(inkCoverage: 0.02, inkComponents: 300, hasLargeDarkArea: false, isBlank: false))
        XCTAssertEqual(step.apply(printed).upright, UprightTurn(quarterTurns: 2))
    }

    func test_step_doesNotReadBarcodeSeparatorSheets_butTurnsPagesACodeStartsADocumentWith() {
        let scorer = likeALetter()
        var split = DocumentOptions()
        split.splitMode = .barcode
        let sheet = page(textRgba.rotatedQuarterTurns(2))
            .withBarcodes([BarcodeReading(symbology: .qrCode, text: "CS-SEP Lease", bounds: CGRect(x: 10, y: 10, width: 20, height: 20))])
        let skipped = OrientationStep(scorer: scorer, split: split).apply(sheet)
        XCTAssertNil(skipped.upright)
        XCTAssertTrue(skipped.image === sheet.image)
        XCTAssertEqual(scorer.seen, [])
        // Without the split's options, or under another split, the page is read.
        XCTAssertEqual(OrientationStep(scorer: likeALetter()).apply(sheet).upright, UprightTurn(quarterTurns: 2))
        var patchSplit = DocumentOptions()
        patchSplit.splitMode = .separatorSheet
        XCTAssertEqual(OrientationStep(scorer: likeALetter(), split: patchSplit).apply(sheet).upright, UprightTurn(quarterTurns: 2))
        // A code of the page's own (no separator code) is read.
        let invoice = page(textRgba.rotatedQuarterTurns(2))
            .withBarcodes([BarcodeReading(symbology: .code128, text: "ORDER-4711", bounds: CGRect(x: 10, y: 10, width: 20, height: 2))])
        XCTAssertEqual(OrientationStep(scorer: likeALetter(), split: split).apply(invoice).upright, UprightTurn(quarterTurns: 2))
        // A barcode starting a document keeps the page: it is turned upright.
        var starts = split
        starts.barcodeStartsDocument = true
        XCTAssertEqual(OrientationStep(scorer: likeALetter(), split: starts).apply(sheet).upright, UprightTurn(quarterTurns: 2))
        // The step keeps the options it was given.
        let step = OrientationStep(scorer: likeALetter(), split: split)
        split.barcodeStartsDocument = true
        XCTAssertEqual(step.split?.barcodeStartsDocument, false)
    }

    func test_step_passesShouldContinueOn() {
        let step = OrientationStep(scorer: likeALetter())
        XCTAssertThrowsError(try step.apply(page(textRgba), shouldContinue: { false })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
        var s = ScanSettings()
        s.document.autoRotate = true
        let processor = PageProcessor.forScan(s, scorer: likeALetter())
        // Asked before the scan, the page and each of its three steps, then by the orientation step:
        // before it starts and before its first reading, where it stops.
        var asked = 0
        XCTAssertThrowsError(try processor.process([page(textRgba)], shouldContinue: {
            asked += 1
            return asked < 7
        })) { error in
            guard case ScanError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(asked, 7)
    }

    func test_process_turnsAPageScannedUpsideDown_upright() throws {
        var s = ScanSettings()
        s.document.autoRotate = true
        let upsideDownPage = page(textRgba.rotatedQuarterTurns(2))
        let result = try PageProcessor.forScan(s, scorer: likeALetter())
            .process([page(textRgba), upsideDownPage, page(blankRgba)])
        XCTAssertEqual(result.pages.map(\.upright), [nil, UprightTurn(quarterTurns: 2), nil])
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: result.pages[0].image)!), 0)
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: result.pages[1].image)!), 0)
        XCTAssertEqual(PageTurns.scanNote(result.pages), " 1 turned upright.")
        // The preview and the history keep the page as scanned.
        XCTAssertTrue(result.arranged[1].image === upsideDownPage.image)
    }

    // MARK: Undoing a turn

    func test_turnedUpright_turnsThePixels_andToggledTurnsThemBack() {
        let scanned = textRgba.rotatedQuarterTurns(1).makeCGImage()!
        let start = ScannedPage(image: scanned, dpi: 100, colorMode: .color)
        let turned = start.turnedUpright(3)
        XCTAssertEqual(turned.upright, UprightTurn(quarterTurns: 3))
        XCTAssertEqual(pixels(turned.image), pixels(ImagePipeline.rotate(scanned, quarterTurns: 3)))
        XCTAssertEqual(turned.rotationQuarterTurns, 0)
        let undone = turned.withUprightToggled()
        XCTAssertEqual(undone.upright, UprightTurn(quarterTurns: 3, undone: true))
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: turned.image)!), 0)
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: undone.image)!), 1)
        XCTAssertEqual(undone.rotationQuarterTurns, 0)
        let again = undone.withUprightToggled()
        XCTAssertEqual(again.upright, UprightTurn(quarterTurns: 3))
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: again.image)!), 0)
        XCTAssertEqual(again.id, start.id)
        // No turn, nothing recorded; a page not turned has nothing to undo.
        let plain = page(textRgba)
        XCTAssertTrue(plain.turnedUpright(0).image === plain.image)
        XCTAssertNil(plain.turnedUpright(4).upright)
        XCTAssertTrue(plain.withUprightToggled().image === plain.image)
        XCTAssertNil(plain.withUprightToggled().upright)
    }

    func test_withUprightToggled_spooledPage_turnsThroughTheRotation_likeATurnByHand() {
        let preview = textRgba.rotatedQuarterTurns(1).resized(width: 85, height: 110).makeCGImage()!
        let url = URL(fileURLWithPath: "/tmp/page.tiff")
        let start = page(textRgba)
            .withImage(preview, fileURL: url, fullPixelSize: CGSize(width: 850, height: 1100))
            .withAlternate(PageVersion(image: nil, fileURL: URL(fileURLWithPath: "/tmp/page-other.tiff"),
                                       fullPixelSize: CGSize(width: 900, height: 1200)))
            .withUpright(UprightTurn(quarterTurns: 1))
        let undone = start.withUprightToggled()
        XCTAssertEqual(undone.rotationQuarterTurns, 3)
        XCTAssertEqual(pixels(undone.image), pixels(ImagePipeline.rotate(preview, quarterTurns: 3)))
        XCTAssertEqual(undone.fileURL, url)
        XCTAssertEqual(undone.fullPixelSize, CGSize(width: 850, height: 1100))
        XCTAssertEqual(undone.alternate?.fileURL, start.alternate?.fileURL)
        XCTAssertNil(undone.alternate?.image)
        XCTAssertEqual(undone.upright?.undone, true)
        let again = undone.withUprightToggled()
        XCTAssertEqual(again.rotationQuarterTurns, 0)
        XCTAssertEqual([again.image.width, again.image.height], [preview.width, preview.height])
        // Turned by the step after spooling (not how the app does it): through the rotation too.
        XCTAssertEqual(page(textRgba).withImage(preview, fileURL: url).turnedUpright(2).rotationQuarterTurns, 2)
    }

    func test_withUprightToggled_pageInMemory_otherVersionSpooled_turnsTheFileThroughTheRotation() {
        // Shown: the page as scanned, kept in memory (its spool file failed), turned upright by a
        // quarter turn; the other version (cropped and straightened, upright) has a spool file.
        let otherURL = URL(fileURLWithPath: "/tmp/page.tiff")
        let start = page(textRgba)
            .withAlternate(PageVersion(image: nil, fileURL: otherURL, fullPixelSize: CGSize(width: 100, height: 130)))
            .withUpright(UprightTurn(quarterTurns: 1))
        let undone = start.withUprightToggled()
        XCTAssertEqual(undone.rotationQuarterTurns, 3)
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: undone.image)!), 3)
        XCTAssertNil(undone.fileURL)
        XCTAssertEqual(undone.alternate?.fileURL, otherURL)
        XCTAssertNil(undone.alternate?.image)
        // Saved from memory, the rotation is not applied again: as scanned.
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: PDFBuilder.preparePage(undone).image)!), 3)
        // The other version, read from its file and turned like the page: as scanned too.
        let fromFile = textRgba.rotatedQuarterTurns(undone.rotationQuarterTurns).makeCGImage()!
        let swapped = undone.withVersionsSwapped(fromFile)
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: swapped.image)!), 3)
        XCTAssertEqual(swapped.rotationQuarterTurns, 3)
        // Turned upright again: both back upright.
        let again = undone.withUprightToggled()
        XCTAssertEqual(again.rotationQuarterTurns, 0)
        XCTAssertEqual(turnsFromUpright(RgbaImage(cgImage: again.image)!), 0)
    }

    func test_upright_survivesRebuildingThePage() {
        let text = textRgba.makeCGImage()!
        let start = page(textRgba).turnedUpright(2)
            .withGeometry(text, geometry: PageGeometry(cropped: true, angleDegrees: 0, basis: .pageEdges))
        let turn = UprightTurn(quarterTurns: 2)
        let rebuilt: [ScannedPage] = [
            start.withImage(RgbaImage.filled(width: 3, height: 3, r: 0, g: 0, b: 0).makeCGImage()!),
            start.withSide(.front, sheetIndex: 0),
            start.withBlank(nil),
            start.withInclusion(.skip),
            start.withPatch(nil),
            start.withDocumentBreak(.split),
            start.withDocumentLabel("Lease"),
            start.withAlternate(nil),
            start.withVersionsSwapped(text),
            start.withGeometry(text, geometry: PageGeometry(cropped: false, angleDegrees: 2, basis: .textLines)),
            page(blankRgba).copyMeta(from: start),
        ]
        for copy in rebuilt {
            XCTAssertEqual(copy.upright, turn)
        }
        XCTAssertNil(page(textRgba).upright)
        XCTAssertNil(start.withUpright(nil).upright)
    }

    // MARK: What the strip and the status say

    func test_pageTurns_sayWhatWasDone_andWhatOneClickDoes() {
        let half = page(textRgba).turnedUpright(2)
        XCTAssertEqual(PageTurns.caption(half), "Turned upright 180°")
        XCTAssertEqual(PageTurns.caption(page(textRgba).turnedUpright(1)), "Turned upright 90° clockwise")
        XCTAssertEqual(PageTurns.caption(page(textRgba).turnedUpright(3)), "Turned upright 90° counterclockwise")
        XCTAssertEqual(PageTurns.toggleLabel(half), "Undo turn")
        XCTAssertEqual(PageTurns.toggleNote(half, number: 2), "Page 2 is turned upright again.")
        let undone = half.withUprightToggled()
        XCTAssertEqual(PageTurns.caption(undone), "Turned back as scanned")
        XCTAssertEqual(PageTurns.toggleLabel(undone), "Turn upright again")
        XCTAssertEqual(PageTurns.toggleNote(undone, number: 2), "Page 2 is turned back as scanned. It is saved that way.")
        XCTAssertNil(PageTurns.caption(page(textRgba)))
        XCTAssertNil(PageTurns.toggleLabel(page(textRgba)))
        XCTAssertEqual(PageTurns.scanNote([half, page(textRgba).turnedUpright(1), undone, page(textRgba)]), " 2 turned upright.")
        XCTAssertEqual(PageTurns.scanNote([half]), " 1 turned upright.")
        XCTAssertEqual(PageTurns.scanNote([undone, page(textRgba)]), "")
    }

    func test_pageTurns_hint_saysWhyTheSwitchIsOff_orWhatItDoes() {
        var s = ScanSettings()
        XCTAssertEqual(PageTurns.hint(s, available: true), "Turns sideways or upside-down pages by reading the text")
        s.document.autoRotate = true
        XCTAssertEqual(PageTurns.hint(s, available: true), "Turns sideways or upside-down pages by reading the text")
        XCTAssertEqual(PageTurns.hint(s, available: false), "Needs a text recognition language, and none is installed.")
        var atOnce = ScanSettings()
        atOnce.documentMultiPage = false
        XCTAssertEqual(PageTurns.hint(atOnce, available: true),
                       "Only for pages collected before saving: a scan saved at once is kept as scanned.")
        XCTAssertEqual(PageTurns.hint(TaskCatalog.apply(.copy, to: ScanSettings()), available: true),
                       "Copies print every page as scanned: pages are not turned.")
        XCTAssertEqual(PageTurns.hint(TaskCatalog.apply(.receipt, to: ScanSettings()), available: true),
                       "Receipts are kept the way they lie on the glass.")
        XCTAssertTrue(PageTurns.unavailableNote.hasPrefix(" Pages were not turned upright"))
    }
}
