import CoreGraphics
import XCTest
@testable import CompleteScannerKit

// Twin of windows/CompleteScanner.Core.Tests/DocumentSplitterTests.cs: the same cases.

private let plain = PageFacts()
private let blank = PageFacts(looksBlank: true)
private let patch = PageFacts(patch: .patchT)

private func front(_ sheet: Int, blank: Bool = false, patch: PatchCode? = nil) -> PageFacts {
    PageFacts(sheetIndex: sheet, side: .front, looksBlank: blank, patch: patch)
}

private func back(_ sheet: Int, blank: Bool = false, patch: PatchCode? = nil) -> PageFacts {
    PageFacts(sheetIndex: sheet, side: .back, looksBlank: blank, patch: patch)
}

private func options(_ mode: SplitMode, removeBlankPages: Bool = false, sheets: Int = 1) -> DocumentOptions {
    var o = DocumentOptions()
    o.splitMode = mode
    o.removeBlankPages = removeBlankPages
    o.splitSheetCount = sheets
    return o
}

private func documents(_ plan: SplitPlan) -> [[Int]] { plan.documents.map(\.pages) }

private func roles(_ plan: SplitPlan) -> String {
    String(plan.pages.map { page -> Character in
        switch page.role {
        case .content: return "c"
        case .skipped: return "s"
        case .separator: return "x"
        }
    })
}

private func with(_ facts: PageFacts, documentBreak: DocumentBreak? = nil, inclusion: PageInclusion? = nil,
                  label: String? = nil) -> PageFacts {
    var f = facts
    if let documentBreak { f.documentBreak = documentBreak }
    if let inclusion { f.inclusion = inclusion }
    if let label { f.label = label }
    return f
}

private let looksBlankResult = BlankPageResult(inkCoverage: 0, inkComponents: 0, hasLargeDarkArea: false, isBlank: true)
private let whiteImage: CGImage = RgbaImage.filled(width: 4, height: 4, r: 255, g: 255, b: 255).makeCGImage()!

private func makePage(blank: Bool = false, patch: PatchCode? = nil) -> ScannedPage {
    ScannedPage(image: whiteImage, dpi: 300, colorMode: .color)
        .withBlank(blank ? looksBlankResult : nil)
        .withPatch(patch)
}

final class DocumentSplitterTests: XCTestCase {
    func test_sheets_aFrontAndItsBackShareASheet() {
        XCTAssertEqual(DocumentSplitter.sheets([plain, plain, plain]), [0, 1, 2])
        XCTAssertEqual(DocumentSplitter.sheets([front(0), back(0), front(1), back(1), front(2)]), [0, 0, 1, 1, 2])
        // A back without its front, or of another sheet, is a sheet of its own.
        XCTAssertEqual(DocumentSplitter.sheets([back(0), front(1), back(2), plain]), [0, 1, 2, 3])
        XCTAssertEqual(DocumentSplitter.sheets([front(0), back(0), back(0), front(0)]), [0, 0, 1, 2])
        XCTAssertEqual(DocumentSplitter.sheets([]), [])
    }

    func test_off_oneDocument_skippedPagesAsTheBlankPageSettingSays() {
        let facts = [plain, patch, blank, plain]
        let plan = DocumentSplitter.plan(facts, options: options(.none))
        XCTAssertEqual(documents(plan), [[0, 1, 2, 3]])
        XCTAssertEqual(roles(plan), "cccc")
        XCTAssertFalse(plan.isSplit)
        let skipping = DocumentSplitter.plan(facts, options: options(.none, removeBlankPages: true))
        XCTAssertEqual(documents(skipping), [[0, 1, 3]])
        XCTAssertEqual(roles(skipping), "ccsc")
        XCTAssertEqual(skipping.separatorCount, 0)
        XCTAssertEqual(skipping.skippedCount, 1)
        XCTAssertEqual(skipping.pageCount, 3)
        XCTAssertTrue(DocumentSplitter.plan([PageFacts](), options: options(.separatorSheet)).documents.isEmpty)
    }

    func test_separatorSheets_oneSided_startANewDocumentAndAreLeftOut() {
        let plan = DocumentSplitter.plan([plain, plain, patch, plain, patch, plain, plain], options: options(.separatorSheet))
        XCTAssertEqual(documents(plan), [[0, 1], [3], [5, 6]])
        XCTAssertEqual(roles(plan), "ccxcxcc")
        XCTAssertEqual(plan.documents.map(\.number), [1, 2, 3])
        XCTAssertEqual(plan.separatorCount, 2)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(plan.pageCount, 5)
        XCTAssertEqual(plan.pages.map(\.startsDocument), [true, false, false, true, false, true, false])
        XCTAssertEqual(plan.pages.map(\.document), [1, 1, nil, 2, nil, 3, 3])
        XCTAssertTrue(plan.isSplit)
    }

    func test_separatorSheets_twoSided_theWholeSheetIsLeftOut_blankBacksFollowTheSetting() {
        // A printed sheet with a blank back, the separator (blank back), a printed sheet both sides.
        let facts = [front(0), back(0, blank: true), front(1, patch: .patchT), back(1, blank: true), front(2), back(2)]
        let plan = DocumentSplitter.plan(facts, options: options(.separatorSheet, removeBlankPages: true))
        XCTAssertEqual(documents(plan), [[0], [4, 5]])
        XCTAssertEqual(roles(plan), "csxxcc")
        XCTAssertEqual(plan.pages.map(\.sheet), [0, 0, 1, 1, 2, 2])
        let keepingBlanks = DocumentSplitter.plan(facts, options: options(.separatorSheet))
        XCTAssertEqual(documents(keepingBlanks), [[0, 1], [4, 5]])
        // A sheet fed the other way round has its code on the back.
        let turned = [front(0), back(0), front(1, blank: true), back(1, patch: .patch3), front(2), back(2)]
        XCTAssertEqual(documents(DocumentSplitter.plan(turned, options: options(.separatorSheet))), [[0, 1], [4, 5]])
    }

    func test_separators_inARowCountOnce_andEmptyDocumentsAreDropped() {
        let mode = options(.separatorSheet)
        XCTAssertEqual(documents(DocumentSplitter.plan([patch, patch, plain, patch, patch, plain, patch], options: mode)), [[2], [5]])
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, patch], options: mode)), [[0]])
        XCTAssertTrue(DocumentSplitter.plan([patch, patch], options: mode).documents.isEmpty)
        // A document of blank pages only, all skipped, is no document.
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, patch, blank, patch, plain],
                                                       options: options(.separatorSheet, removeBlankPages: true))),
                       [[0], [4]])
    }

    func test_blankSheets_oneSided_everyBlankPageSplits() {
        let facts = [plain, blank, plain, blank, blank, plain]
        for remove in [false, true] {
            let plan = DocumentSplitter.plan(facts, options: options(.blankSheet, removeBlankPages: remove))
            XCTAssertEqual(documents(plan), [[0], [2], [5]])
            XCTAssertEqual(roles(plan), "cxcxxc")
        }
        // A patch code is no separator here.
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, patch, plain], options: options(.blankSheet))), [[0, 1, 2]])
    }

    func test_blankSheets_twoSided_onlyASheetBlankOnBothSidesSplits() {
        let facts = [
            front(0), back(0, blank: true),
            front(1, blank: true), back(1, blank: true),
            front(2), back(2),
            front(3), back(3, blank: true),
        ]
        let plan = DocumentSplitter.plan(facts, options: options(.blankSheet))
        XCTAssertEqual(documents(plan), [[0, 1], [4, 5, 6, 7]])
        XCTAssertEqual(roles(plan), "ccxxcccc")
        let skipping = DocumentSplitter.plan(facts, options: options(.blankSheet, removeBlankPages: true))
        XCTAssertEqual(documents(skipping), [[0], [4, 5, 6]])
        XCTAssertEqual(roles(skipping), "csxxcccs")
        // An odd last front that is blank is a sheet blank on every side.
        XCTAssertEqual(documents(DocumentSplitter.plan([front(0), back(0), front(1, blank: true)], options: options(.blankSheet))),
                       [[0, 1]])
    }

    func test_everyNSheets_countsEverySheet_blankOnesToo() {
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, plain, plain, plain, plain], options: options(.sheetCount, sheets: 2))),
                       [[0, 1], [2, 3], [4]])
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, plain, plain], options: options(.sheetCount, sheets: 1))),
                       [[0], [1], [2]])
        // Two-sided: sheets, not pages, are counted; an odd last sheet makes a short document.
        XCTAssertEqual(documents(DocumentSplitter.plan([front(0), back(0), front(1), back(1), front(2)], options: options(.sheetCount))),
                       [[0, 1], [2, 3], [4]])
        // A skipped blank page still counts as a sheet; a document whose first sheet is skipped starts at its next page.
        let remove = options(.sheetCount, removeBlankPages: true, sheets: 2)
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, blank, plain, plain, plain], options: remove)), [[0], [2, 3], [4]])
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, plain, blank, plain], options: remove)), [[0, 1], [3]])
        // A patch code or a blank sheet is no separator here.
        XCTAssertEqual(documents(DocumentSplitter.plan([patch, blank, plain], options: options(.sheetCount, sheets: 2))), [[0, 1], [2]])
        XCTAssertEqual([0, 5000, -3, 999].map(DocumentSplitter.clampSheetCount), [1, 999, 1, 999])
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, plain, plain], options: options(.sheetCount, sheets: 0))),
                       [[0], [1], [2]])
    }

    func test_theUsersSplitsAndJoinsWin() {
        let split = with(plain, documentBreak: .split)
        let join = with(plain, documentBreak: .join)
        // A split by hand, with no split chosen.
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, plain, split, plain], options: options(.none))), [[0, 1], [2, 3]])
        // A join where a separator would start a document.
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, patch, join, plain], options: options(.separatorSheet))), [[0, 2, 3]])
        // A split on the first page saved changes nothing.
        XCTAssertEqual(documents(DocumentSplitter.plan([split, plain], options: options(.none))), [[0, 1]])
        // A split on a page left out does not carry over.
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, with(blank, documentBreak: .split), plain],
                                                       options: options(.none, removeBlankPages: true))),
                       [[0, 2]])
        // Every N sheets goes on counting after a join.
        XCTAssertEqual(documents(DocumentSplitter.plan([plain, plain, join, plain, plain, plain], options: options(.sheetCount, sheets: 2))),
                       [[0, 1, 2, 3], [4, 5]])
    }

    func test_toggledBreak_twoClicksUndoOne() {
        let o = options(.separatorSheet)
        var facts = [plain, plain, patch, plain, plain]
        // The gap before page 1: a split by hand.
        XCTAssertTrue(DocumentSplitter.canToggleBreak(DocumentSplitter.plan(facts, options: o), 1))
        XCTAssertEqual(DocumentSplitter.toggledBreak(facts, 1, options: o), .split)
        facts[1].documentBreak = .split
        XCTAssertEqual(documents(DocumentSplitter.plan(facts, options: o)), [[0], [1], [3, 4]])
        XCTAssertEqual(DocumentSplitter.toggledBreak(facts, 1, options: o), .automatic)
        // The page after the separator starts a document: a click joins it.
        XCTAssertEqual(DocumentSplitter.toggledBreak(facts, 3, options: o), .join)
        facts[3].documentBreak = .join
        XCTAssertEqual(documents(DocumentSplitter.plan(facts, options: o)), [[0], [1, 3, 4]])
        XCTAssertEqual(DocumentSplitter.toggledBreak(facts, 3, options: o), .automatic)
        // The first page saved and a separator page have no gap to click.
        let plan = DocumentSplitter.plan(facts, options: o)
        XCTAssertFalse(DocumentSplitter.canToggleBreak(plan, 0))
        XCTAssertFalse(DocumentSplitter.canToggleBreak(plan, 2))
        XCTAssertFalse(DocumentSplitter.canToggleBreak(plan, 7))
        XCTAssertEqual(DocumentSplitter.toggledBreak(facts, 0, options: o), .automatic)
        XCTAssertEqual(DocumentSplitter.toggledBreak(facts, 2, options: o), .automatic)
    }

    func test_toggledInclusion_keepsASeparatorPage_andTwoClicksUndoOne() {
        let o = options(.separatorSheet, removeBlankPages: true)
        var facts = [plain, front(0, patch: .patchT), back(0, blank: true), plain]
        XCTAssertEqual(DocumentSplitter.toggledInclusion(facts, 1, options: o), .keep)
        facts[1].inclusion = .keep
        // Kept, the sheet no longer splits; its blank back is still skipped.
        let plan = DocumentSplitter.plan(facts, options: o)
        XCTAssertEqual(documents(plan), [[0, 1, 3]])
        XCTAssertEqual(roles(plan), "ccsc")
        XCTAssertEqual(DocumentSplitter.toggledInclusion(facts, 1, options: o), .automatic)
        // A page saved: a click skips it, a second click follows the settings again.
        XCTAssertEqual(DocumentSplitter.toggledInclusion(facts, 0, options: o), .skip)
        // A blank page skipped by the setting: kept, like PageFilter.toggled.
        XCTAssertEqual(DocumentSplitter.toggledInclusion(facts, 2, options: o), .keep)
    }

    func test_names_theFirstNameAmongADocumentsPagesSaved() {
        let facts = [
            with(plain, label: "  "), with(plain, label: " Lease "), with(plain, label: "Other"),
            with(patch, label: "Separator"), with(blank, label: "Skipped"), plain,
        ]
        let plan = DocumentSplitter.plan(facts, options: options(.separatorSheet, removeBlankPages: true))
        XCTAssertEqual(plan.documents.map(\.label), ["Lease", nil])
        XCTAssertEqual(DocumentSplitter.documentTitle(plan.documents[0]), "Document 1 · Lease")
        XCTAssertEqual(DocumentSplitter.documentTitle(plan.documents[1]), "Document 2")
        XCTAssertNil(DocumentSplitter.cleaned("  "))
        XCTAssertEqual(DocumentSplitter.cleaned(" A b "), "A b")
        // A long name is cut to 100 characters, never inside one.
        XCTAssertEqual(DocumentSplitter.cleaned(String(repeating: "a", count: 300)), String(repeating: "a", count: 100))
        XCTAssertEqual(DocumentSplitter.cleaned(String(repeating: "a", count: 99) + " and more"), String(repeating: "a", count: 99))
        XCTAssertEqual(DocumentSplitter.cleaned(String(repeating: "😀", count: 101)), String(repeating: "😀", count: 100))
    }

    private func toggled(_ facts: [PageFacts], _ index: Int, inclusion: PageInclusion? = nil,
                         documentBreak: DocumentBreak? = nil) -> [PageFacts] {
        var after = facts
        if let inclusion { after[index].inclusion = inclusion }
        if let documentBreak { after[index].documentBreak = documentBreak }
        let labels = DocumentSplitter.carriedLabels(facts, after, options: options(.separatorSheet))
        for i in after.indices { after[i].label = labels[i] }
        return after
    }

    private func names(_ facts: [PageFacts]) -> [String?] {
        DocumentSplitter.plan(facts, options: options(.separatorSheet)).documents.map(\.label)
    }

    func test_carriedLabels_skippingANamedFirstPage_movesTheNameToTheNextPage_andKeepingItMovesItBack() {
        // Document 2 is pages 3 and 4, named on page 3.
        let facts = [plain, plain, patch, with(plain, label: "Lease"), plain]
        let skipped = toggled(facts, 3, inclusion: .skip)
        XCTAssertEqual(names(skipped), [nil, "Lease"])
        XCTAssertEqual(skipped.map(\.label), [nil, nil, nil, nil, "Lease"])
        let kept = toggled(skipped, 3, inclusion: .automatic)
        XCTAssertEqual(names(kept), [nil, "Lease"])
        XCTAssertEqual(kept.map(\.label), [nil, nil, nil, "Lease", nil])
    }

    func test_carriedLabels_aPageSavedAgainBeforeANamedDocument_takesItsLatestName_notAnOldOne() {
        // Page 3 is skipped and still holds an old name; the document starting at page 4 is named "New".
        var facts = [plain, patch, with(plain, inclusion: .skip, label: "Old"), with(plain, label: "New"), plain]
        XCTAssertEqual(names(facts), [nil, "New"])
        let kept = toggled(facts, 2, inclusion: .automatic)
        XCTAssertEqual(names(kept), [nil, "New"])
        XCTAssertEqual(kept.map(\.label), [nil, nil, "New", nil, nil])
        // A document with no name stays without one: the old name is cleared.
        facts[3].label = nil
        XCTAssertEqual(names(toggled(facts, 2, inclusion: .automatic)), [nil, nil])
    }

    func test_carriedLabels_aDocumentThatIsGone_comesBackWithItsName_andSplitsAndJoinsKeepNames() {
        // Document 2 is page 3 alone: skipped, it is gone; kept again, it has its name back.
        let facts = [plain, patch, with(plain, label: "Cover"), patch, with(plain, label: "Body")]
        let gone = toggled(facts, 2, inclusion: .skip)
        XCTAssertEqual(names(gone), [nil, "Body"])
        XCTAssertEqual(gone[2].label, "Cover")
        XCTAssertEqual(names(toggled(gone, 2, inclusion: .automatic)), [nil, "Cover", "Body"])
        // Joined to the document before and split off again: the second document keeps its name.
        let two = [with(plain, label: "A"), patch, with(plain, label: "B"), plain]
        let joined = toggled(two, 2, documentBreak: .join)
        XCTAssertEqual(names(joined), ["A"])
        XCTAssertEqual(names(toggled(joined, 2, documentBreak: .automatic)), ["A", "B"])
        // Split by hand inside a named document: the new document has no name, the first keeps its.
        XCTAssertEqual(names(toggled(two, 3, documentBreak: .split)), ["A", "B", nil])
        // Nothing changed: the names stay as they are.
        XCTAssertEqual(DocumentSplitter.carriedLabels(two, two, options: options(.separatorSheet)), two.map(\.label))
    }

    private func carried(_ before: [PageFacts], _ beforeOptions: DocumentOptions, _ after: [PageFacts],
                         _ afterOptions: DocumentOptions) -> [PageFacts] {
        let labels = DocumentSplitter.carriedLabels(before, beforeOptions: beforeOptions, after, options: afterOptions)
        var result = after
        for i in result.indices { result[i].label = labels[i] }
        return result
    }

    func test_carriedLabels_aSettingThatLeavesOutANamedFirstPage_movesTheName_andChangingItBackMovesItBack() {
        // Document 2 starts with a nearly empty cover named "Lease": blank only at High.
        let medium = options(.separatorSheet, removeBlankPages: true)
        var high = options(.separatorSheet, removeBlankPages: true)
        high.blankSensitivity = .high
        let facts = [plain, patch, with(plain, label: "Lease"), plain]
        var blankAtHigh = facts
        blankAtHigh[2].looksBlank = true
        let sensitive = carried(facts, medium, blankAtHigh, high)
        XCTAssertEqual(DocumentSplitter.plan(sensitive, options: high).documents.map(\.label), [nil, "Lease"])
        XCTAssertEqual(sensitive.map(\.label), [nil, nil, nil, "Lease"])
        var notBlank = sensitive
        for i in notBlank.indices { notBlank[i].looksBlank = false }
        XCTAssertEqual(carried(sensitive, high, notBlank, medium).map(\.label), [nil, nil, "Lease", nil])
        // Skip blank pages turned on, and off again.
        let off = options(.separatorSheet)
        let skipping = carried(blankAtHigh, off, blankAtHigh, medium)
        XCTAssertEqual(skipping.map(\.label), [nil, nil, nil, "Lease"])
        XCTAssertEqual(carried(skipping, medium, skipping, off).map(\.label), [nil, nil, "Lease", nil])
    }

    func test_carriedLabels_aSplitChosenLater_givesTheNameToOneDocument() {
        // Named while not split, on a separator sheet first in the stack: at separator sheets the
        // first document takes the name, the next has none; not split again, the name is back.
        let facts = [with(patch, label: "Lease"), plain, patch, plain]
        let none = options(.none)
        let separators = options(.separatorSheet)
        let split = carried(facts, none, facts, separators)
        XCTAssertEqual(DocumentSplitter.plan(split, options: separators).documents.map(\.label), ["Lease", nil])
        XCTAssertEqual(split.map(\.label), [nil, "Lease", nil, nil])
        XCTAssertEqual(carried(split, separators, split, none).map(\.label), ["Lease", nil, nil, nil])
        // Every 2 sheets: the first document keeps the name where it is.
        let named = [with(plain, label: "L"), plain, plain, plain]
        XCTAssertEqual(carried(named, none, named, options(.sheetCount, sheets: 2)).map(\.label), ["L", nil, nil, nil])
    }

    func test_blankPagesAreSeparators_onlyOneSidedAtBlankSheets() {
        XCTAssertTrue(DocumentSplitter.blankPagesAreSeparators(options(.blankSheet), sides: .off))
        XCTAssertFalse(DocumentSplitter.blankPagesAreSeparators(options(.blankSheet), sides: .both))
        XCTAssertFalse(DocumentSplitter.blankPagesAreSeparators(options(.blankSheet), sides: .manual))
        XCTAssertFalse(DocumentSplitter.blankPagesAreSeparators(options(.separatorSheet), sides: .off))
        XCTAssertFalse(DocumentSplitter.blankPagesAreSeparators(options(SplitMode.none), sides: .off))
        // There, the setting makes no difference to the plan.
        let facts = [plain, blank, plain, with(blank, inclusion: .keep), plain]
        XCTAssertEqual(roles(DocumentSplitter.plan(facts, options: options(.blankSheet, removeBlankPages: false))),
                       roles(DocumentSplitter.plan(facts, options: options(.blankSheet, removeBlankPages: true))))
    }

    func test_texts_forThePageStrip() {
        let o = options(.separatorSheet)
        let plan = DocumentSplitter.plan([plain, patch, plain, plain], options: o)
        XCTAssertEqual((0..<4).map { DocumentSplitter.dividerTitle(plan, $0) }, ["Document 1", nil, "Document 2", nil])
        XCTAssertEqual((0..<4).map { DocumentSplitter.breakLabel(plan, $0) },
                       [nil, nil, "Join with document 1", "Start a new document here"])
        XCTAssertTrue(DocumentSplitter.showsBreaks(plan, options: o))
        // One document: no titles; the dividers show only while a split is chosen.
        let single = DocumentSplitter.plan([plain, plain], options: options(.none))
        XCTAssertNil(DocumentSplitter.dividerTitle(single, 0))
        XCTAssertFalse(DocumentSplitter.showsBreaks(single, options: options(.none)))
        XCTAssertTrue(DocumentSplitter.showsBreaks(single, options: options(.blankSheet)))
        XCTAssertTrue(DocumentSplitter.showsBreaks(DocumentSplitter.plan([plain, with(plain, documentBreak: .split)], options: options(.none)),
                                                   options: options(.none)))
        XCTAssertEqual(DocumentSplitter.scanNote(plan, separatorsAdded: 1), " Found 1 separator page: 2 documents to save.")
        XCTAssertEqual(DocumentSplitter.scanNote(plan, separatorsAdded: 0), " 2 documents to save.")
        XCTAssertEqual(DocumentSplitter.scanNote(single, separatorsAdded: 0), "")
        XCTAssertEqual(DocumentSplitter.scanNote(single, separatorsAdded: 2), " Found 2 separator pages: 1 document to save.")
    }

    func test_thePlanOfQueuedPages_usesWhatTheirChecksFound() {
        let pages = [
            makePage(), makePage(patch: .patch2).withDocumentLabel("ignored"), makePage(blank: true),
            makePage().withDocumentLabel("Lease"), makePage().withDocumentBreak(.split),
        ]
        let o = options(.separatorSheet, removeBlankPages: true)
        XCTAssertEqual(PageFacts.of(pages[1], options: o).patch, .patch2)
        XCTAssertTrue(PageFacts.of(pages[2], options: o).looksBlank)
        XCTAssertEqual(PageFacts.of(pages[4], options: o).documentBreak, .split)
        let plan = DocumentSplitter.plan(pages, options: o)
        XCTAssertEqual(documents(plan), [[0], [3], [4]])
        XCTAssertEqual(plan.documents.map(\.label), [nil, "Lease", nil])
        // The strip's notes.
        XCTAssertEqual(DocumentSplitter.badge(plan, 1, page: pages[1], options: o), "Separator")
        XCTAssertEqual(DocumentSplitter.badge(plan, 2, page: pages[2], options: o), "Blank, skipped")
        XCTAssertNil(DocumentSplitter.badge(plan, 0, page: pages[0], options: o))
        XCTAssertEqual(DocumentSplitter.toggleLabel(plan, 1, page: pages[1], options: o), "Keep this page")
        XCTAssertEqual(DocumentSplitter.toggleLabel(plan, 2, page: pages[2], options: o), "Keep this page")
        XCTAssertNil(DocumentSplitter.toggleLabel(plan, 0, page: pages[0], options: o))
        XCTAssertEqual(DocumentSplitter.separatorNote(plan, 1, page: pages[1]),
                       "Separator sheet (Patch 2): a new document starts after it. It is not saved.")
        XCTAssertNil(DocumentSplitter.separatorNote(plan, 0, page: pages[0]))
        let blankSheets = DocumentSplitter.plan(pages, options: options(.blankSheet))
        XCTAssertEqual(DocumentSplitter.separatorNote(blankSheets, 2, page: pages[2]),
                       "Blank separator sheet: a new document starts after it. It is not saved.")
        // Joined across the sheet: no document starts after it.
        var joined = pages
        joined[3] = pages[3].withDocumentBreak(.join)
        let joinedPlan = DocumentSplitter.plan(joined, options: o)
        XCTAssertEqual(documents(joinedPlan), [[0, 3], [4]])
        XCTAssertEqual(DocumentSplitter.separatorNote(joinedPlan, 1, page: joined[1]),
                       "Separator sheet (Patch 2): the pages after it are joined to the document before. It is not saved.")
        // The strip's label.
        XCTAssertEqual(DocumentSplitter.queueSummary(pages, options: o), "5 pages \u{00B7} 3 documents \u{00B7} 1 separator page and 1 blank skipped")
        XCTAssertEqual(DocumentSplitter.queueSummary(pages, options: options(.none, removeBlankPages: true)),
                       "5 pages \u{00B7} 2 documents \u{00B7} 1 blank skipped")
    }

    func test_queueSummary_withoutASplit_isThePageFiltersSummary() {
        let pages = [makePage(), makePage(blank: true), makePage().withInclusion(.skip), makePage(patch: .patchT)]
        for remove in [false, true] {
            let o = options(.none, removeBlankPages: remove)
            XCTAssertEqual(DocumentSplitter.queueSummary(pages, options: o), PageFilter.queueSummary(pages, options: o))
            let two = Array(pages[..<2])
            XCTAssertEqual(DocumentSplitter.queueSummary(two, options: o), PageFilter.queueSummary(two, options: o))
        }
        XCTAssertEqual(DocumentSplitter.queueSummary([makePage()], options: DocumentOptions()), "1 page")
    }
}
