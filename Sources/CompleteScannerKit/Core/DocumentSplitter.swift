import Foundation

// Twin of windows/CompleteScanner.Core/DocumentSplitter.cs.

/// What saving does with a queued page (`DocumentSplitter.plan`). Twin of C# `PageRole`.
public enum PageRole: Sendable {
    /// Saved, in its document.
    case content
    /// Left out: blank with Skip blank pages on, or skipped by the user (`PageFilter`).
    case skipped
    /// Left out: a side of a separator sheet; the next page starts a new document.
    case separator
}

/// What the split looks at on a queued page: its sheet and side (two-sided scans), whether it looks
/// blank at the chosen sensitivity, the patch code found on it, the user's keep or skip, document
/// break and document name, and the barcode or QR code that splits the stack at it (the first in
/// reading order that does, `BarcodeSeparators.splittingCode`). Twin of C# `PageFacts`.
public struct PageFacts: Equatable, Sendable {
    public var sheetIndex: Int?
    public var side: PageSide?
    public var looksBlank: Bool
    public var patch: PatchCode?
    public var inclusion: PageInclusion
    public var documentBreak: DocumentBreak
    public var label: String?
    public var barcode: BarcodeReading?

    public init(sheetIndex: Int? = nil, side: PageSide? = nil, looksBlank: Bool = false, patch: PatchCode? = nil,
                inclusion: PageInclusion = .automatic, documentBreak: DocumentBreak = .automatic, label: String? = nil,
                barcode: BarcodeReading? = nil) {
        self.sheetIndex = sheetIndex
        self.side = side
        self.looksBlank = looksBlank
        self.patch = patch
        self.inclusion = inclusion
        self.documentBreak = documentBreak
        self.label = label
        self.barcode = barcode
    }

    /// The facts of `page` under `options` (its blank-page sensitivity, the codes that split).
    public static func of(_ page: ScannedPage, options: DocumentOptions) -> PageFacts {
        PageFacts(sheetIndex: page.sheetIndex, side: page.side,
                  looksBlank: PageFilter.looksBlank(page, sensitivity: options.blankSensitivity),
                  patch: page.patch, inclusion: page.inclusion, documentBreak: page.documentBreak,
                  label: page.documentLabel, barcode: BarcodeSeparators.splittingCode(page.barcodes, options: options))
    }
}

/// A queued page in the plan: what saving does with it, the sheet it is on (0 = the queue's first),
/// its document (numbered from 1; nil for a page left out), whether it is that document's first page,
/// and, on a side of a barcode or QR separator sheet, the code that makes the sheet one (read on either
/// side). Twin of C# `PlannedPage`.
public struct PlannedPage: Equatable, Sendable {
    public let role: PageRole
    public let sheet: Int
    public let document: Int?
    public let startsDocument: Bool
    public let code: BarcodeReading?
}

/// A document saving writes: its number (from 1), its pages (queue indices, in order) and its name,
/// if any. Twin of C# `PlannedDocument`.
public struct PlannedDocument: Equatable, Sendable {
    public let number: Int
    public let pages: [Int]
    public let label: String?
}

/// The documents the queue is saved as, and what happens to each queued page. Twin of C# `SplitPlan`.
public struct SplitPlan: Equatable, Sendable {
    public let pages: [PlannedPage]
    public let documents: [PlannedDocument]

    /// Pages left out as sides of separator sheets.
    public var separatorCount: Int { pages.filter { $0.role == .separator }.count }
    /// Pages left out as blank or skipped by the user.
    public var skippedCount: Int { pages.filter { $0.role == .skipped }.count }
    /// Pages saving writes.
    public var pageCount: Int { documents.reduce(0) { $0 + $1.pages.count } }
    /// The queue is saved as more than one document.
    public var isSplit: Bool { documents.count > 1 }
}

/// Splits the collected pages into separate documents (`DocumentOptions.splitMode`) and lets the
/// user adjust where. Nothing is removed from the queue: the page strip shows the plan (separator
/// pages flagged and dimmed, a divider where each document starts), one click on a page keeps a
/// separator page as content or skips a page, one click on the gap before a page starts a new
/// document there or joins it to the one before, and only saving acts on the plan. Twin of C#
/// `DocumentSplitter` (same rules, same texts).
///
/// The rules, over the queue in order. A sheet is a front with its back right after it (two-sided
/// scans, the same sheet index), otherwise a page on its own. At separator sheets: a sheet with a
/// patch code on either side is a separator; both its sides are left out and the next page saved
/// starts a new document. At blank sheets: a sheet blank on every side is a separator (one-sided:
/// each blank page; two-sided: only a sheet blank on both sides, so the blank back of a printed
/// sheet is no separator and follows Skip blank pages). Separators in a row count once, and
/// documents left with no page are dropped. Every few sheets: a new document starts at every Nth
/// sheet, counting every sheet, blank ones too. A page the user keeps makes its sheet no separator;
/// the user's split or join at a page wins over the setting.
///
/// At QR codes or barcodes: a sheet with a code starting with `DocumentOptions.splitBarcodePrefix` on
/// either side is a separator, like a patch-code sheet, and the rest of the code's text names the
/// document after it (the last such sheet before it, when several are in a row); other codes are
/// ignored. With `DocumentOptions.barcodeStartsDocument` a sheet with any code is kept and starts a new
/// document, named by the code (without the prefix, when it has it). The first code that counts on a
/// sheet does (front first, then top to bottom). A name the user gives a document wins over its code's.
public enum DocumentSplitter {
    /// The most sheets per document for `.sheetCount`.
    public static let maxSheetCount = 999

    /// The sheet count as used: 1 to `maxSheetCount`.
    public static func clampSheetCount(_ count: Int) -> Int { min(max(count, 1), maxSheetCount) }

    /// The sheet each page is on, counted from 0: a front followed by its back (the same sheet index)
    /// share a sheet; every other page is a sheet of its own.
    public static func sheets(_ facts: [PageFacts]) -> [Int] {
        var sheets = [Int](repeating: 0, count: facts.count)
        var sheet = -1
        for i in 0..<facts.count {
            var backOfPrevious = false
            if i > 0, facts[i].side == .back, facts[i - 1].side == .front,
               let index = facts[i].sheetIndex, facts[i - 1].sheetIndex == index {
                backOfPrevious = true
            }
            if !backOfPrevious { sheet += 1 }
            sheets[i] = sheet
        }
        return sheets
    }

    /// The plan of `pages` under `options`.
    public static func plan(_ pages: [ScannedPage], options: DocumentOptions) -> SplitPlan {
        plan(pages.map { PageFacts.of($0, options: options) }, options: options)
    }

    /// The documents saving writes and what it does with each page (see the type's remarks for the rules).
    public static func plan(_ facts: [PageFacts], options: DocumentOptions) -> SplitPlan {
        let sheets = self.sheets(facts)
        let mode = options.splitMode
        let perDocument = clampSheetCount(options.splitSheetCount)

        // Which sheets are separators, and the first code on each sheet that splits the stack.
        let sheetCount = facts.isEmpty ? 0 : sheets[sheets.count - 1] + 1
        var separator = [Bool](repeating: false, count: sheetCount)
        var barcode = [BarcodeReading?](repeating: nil, count: sheetCount)
        if mode == .barcode {
            for i in 0..<facts.count where barcode[sheets[i]] == nil {
                if BarcodeSeparators.splits(facts[i].barcode, options: options) { barcode[sheets[i]] = facts[i].barcode }
            }
        }
        if mode == .separatorSheet || mode == .blankSheet || mode == .barcode {
            var kept = [Bool](repeating: false, count: sheetCount)
            var patch = [Bool](repeating: false, count: sheetCount)
            var allBlank = [Bool](repeating: true, count: sheetCount)
            for i in 0..<facts.count {
                let s = sheets[i]
                if facts[i].inclusion == .keep { kept[s] = true }
                if facts[i].patch != nil { patch[s] = true }
                if !facts[i].looksBlank { allBlank[s] = false }
            }
            for s in 0..<sheetCount {
                let marked: Bool
                switch mode {
                case .separatorSheet: marked = patch[s]
                case .blankSheet: marked = allBlank[s]
                default: marked = !options.barcodeStartsDocument && barcode[s] != nil
                }
                separator[s] = !kept[s] && marked
            }
        }

        var pages: [PlannedPage] = []
        var documentPages: [[Int]] = []
        var documentLabels: [String?] = []
        var documentCodeLabels: [String?] = []
        var pending = false
        // The name the next document takes from a code (nil whenever no document is pending).
        var pendingLabel: String?
        var ordinal = 0
        for i in 0..<facts.count {
            let fact = facts[i]
            let sheet = sheets[i]
            let firstOfSheet = i == 0 || sheets[i - 1] != sheet
            if separator[sheet] {
                pages.append(PlannedPage(role: .separator, sheet: sheet, document: nil, startsDocument: false,
                                         code: barcode[sheet]))
                if mode == .barcode && firstOfSheet {
                    pendingLabel = BarcodeSeparators.codeLabel(barcode[sheet]?.text, options: options)
                }
                pending = true
                continue
            }
            if mode == .barcode && options.barcodeStartsDocument && firstOfSheet, let code = barcode[sheet] {
                pending = true
                pendingLabel = BarcodeSeparators.codeLabel(code.text, options: options)
            }
            if mode == .sheetCount && firstOfSheet {
                if ordinal > 0 && ordinal % perDocument == 0 { pending = true }
                ordinal += 1
            }
            let skipped: Bool
            switch fact.inclusion {
            case .keep: skipped = false
            case .skip: skipped = true
            case .automatic: skipped = options.removeBlankPages && fact.looksBlank
            }
            if skipped {
                pages.append(PlannedPage(role: .skipped, sheet: sheet, document: nil, startsDocument: false, code: nil))
                continue
            }
            let starts = documentPages.isEmpty
                || fact.documentBreak == .split
                || (pending && fact.documentBreak != .join)
            if starts {
                documentPages.append([])
                documentLabels.append(nil)
                documentCodeLabels.append(pending ? pendingLabel : nil)
            }
            let last = documentPages.count - 1
            documentPages[last].append(i)
            if documentLabels[last] == nil, let label = cleaned(fact.label) { documentLabels[last] = label }
            pages.append(PlannedPage(role: .content, sheet: sheet, document: documentPages.count, startsDocument: starts,
                                     code: nil))
            pending = false
            pendingLabel = nil
        }
        let documents = documentPages.indices.map {
            PlannedDocument(number: $0 + 1, pages: documentPages[$0], label: documentLabels[$0] ?? documentCodeLabels[$0])
        }
        return SplitPlan(pages: pages, documents: documents)
    }

    /// The longest document name, in characters: a longer one is cut (`cleaned`).
    public static let maxLabelLength = 100

    /// A document name as used: trimmed, and cut to `maxLabelLength` characters (never inside one);
    /// nil when nothing is left.
    public static func cleaned(_ label: String?) -> String? {
        var trimmed = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxLabelLength {
            trimmed = String(trimmed.prefix(maxLabelLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The pages' document names after a change from `before` to `after` (one page's inclusion or
    /// document break): a document whose first saved page changed, because that page is now left
    /// out or a page before it is now saved, keeps the name it showed, now held on its new first
    /// page, and the old first page's name is cleared. Otherwise a page keeps its name, also while
    /// it is left out, so a document that is gone comes back with its name, and a document split off
    /// another has the name its own first page holds. Returns the labels of `after`, changed where
    /// needed; both lists hold the same pages in the same order.
    public static func carriedLabels(_ before: [PageFacts], _ after: [PageFacts], options: DocumentOptions) -> [String?] {
        carriedLabels(before, beforeOptions: options, after, options: options)
    }

    /// The same after a change of the settings too (Skip blank pages, what counts as blank, the
    /// split): `before` is planned under `beforeOptions`, `after` under `options`. A name goes to one
    /// document only: the first that holds a page of the document it named.
    public static func carriedLabels(_ before: [PageFacts], beforeOptions: DocumentOptions, _ after: [PageFacts],
                                     options: DocumentOptions) -> [String?] {
        var labels: [String?] = after.map(\.label)
        guard before.count == after.count else { return labels }
        let old = plan(before, options: beforeOptions)
        let now = plan(after, options: options)
        var carried = Set<Int>()
        for document in now.documents {
            let first = document.pages[0]
            if old.pages[first].startsDocument { continue }
            // The document as it was: the one its first page that was saved before was in.
            guard let kept = document.pages.first(where: { old.pages[$0].role == .content }),
                  let number = old.pages[kept].document else { continue }
            let was = old.documents[number - 1]
            let oldFirst = was.pages[0]
            // That document still starts where it did: this one is split off it.
            if now.pages[oldFirst].startsDocument { continue }
            // A split chosen since can leave its pages in several documents: the first takes the name.
            if !carried.insert(number).inserted { continue }
            // The name the user gave it; a name from a code follows the code by itself.
            labels[first] = userLabel(before, was)
            labels[oldFirst] = nil
        }
        return labels
    }

    /// The first name the user gave among `document`'s pages (as `plan` takes it).
    private static func userLabel(_ facts: [PageFacts], _ document: PlannedDocument) -> String? {
        for page in document.pages {
            if let label = cleaned(facts[page].label) { return label }
        }
        return nil
    }

    /// Skip blank pages has no say: one-sided (`sides` is `.off`) at blank sheets, every blank page
    /// is a separator, which splits the stack and is left out.
    public static func blankPagesAreSeparators(_ options: DocumentOptions, sides: DuplexMode) -> Bool {
        options.splitMode == .blankSheet && sides == .off
    }

    /// Why Skip blank pages is off while `blankPagesAreSeparators` holds.
    public static let blankPagesAreSeparatorsHint =
        "Each blank page splits the stack into documents and is left out: Split into documents is At blank sheets."

    /// Whether a click on the gap before page `index` can split or join there: a page saved, other
    /// than the first page saved.
    public static func canToggleBreak(_ plan: SplitPlan, _ index: Int) -> Bool {
        guard index >= 0, index < plan.pages.count else { return false }
        let page = plan.pages[index]
        return page.role == .content && !(page.document == 1 && page.startsDocument)
    }

    /// The document break after one click on the gap before page `index`: a new document starts
    /// there, or no longer does. A click that agrees with the setting goes back to `.automatic`, so
    /// two clicks undo one. Unchanged where `canToggleBreak` says no.
    public static func toggledBreak(_ facts: [PageFacts], _ index: Int, options: DocumentOptions) -> DocumentBreak {
        let current = plan(facts, options: options)
        guard canToggleBreak(current, index) else { return facts[index].documentBreak }
        let want = !current.pages[index].startsDocument
        var automatic = facts
        automatic[index].documentBreak = .automatic
        let page = plan(automatic, options: options).pages[index]
        let automaticStarts = page.startsDocument && page.document != 1
        if want == automaticStarts { return .automatic }
        return want ? .split : .join
    }

    /// The inclusion after one click on page `index`: the opposite of what saving would do now (a
    /// separator page kept is saved, and its sheet no longer splits). A click that agrees with the
    /// settings goes back to `.automatic`, so two clicks undo one. Like `PageFilter.toggled`, with
    /// separator sheets.
    public static func toggledInclusion(_ facts: [PageFacts], _ index: Int, options: DocumentOptions) -> PageInclusion {
        let excludedNow = plan(facts, options: options).pages[index].role != .content
        var automatic = facts
        automatic[index].inclusion = .automatic
        let automaticExcluded = plan(automatic, options: options).pages[index].role != .content
        let excludeNow = !excludedNow
        if excludeNow == automaticExcluded { return .automatic }
        return excludeNow ? .skip : .keep
    }

    /// The page strip shows where documents start: a split mode is chosen, or the user split the queue.
    public static func showsBreaks(_ plan: SplitPlan, options: DocumentOptions) -> Bool {
        options.splitMode != SplitMode.none || plan.isSplit
    }

    /// "Document 2", or "Document 2 · Invoice 0042" when it has a name.
    public static func documentTitle(_ document: PlannedDocument) -> String {
        if let label = document.label { return "Document \(document.number) · \(label)" }
        return "Document \(document.number)"
    }

    /// The title over page `index` when it starts a document and the queue is saved as several
    /// (`documentTitle`); nil otherwise.
    public static func dividerTitle(_ plan: SplitPlan, _ index: Int) -> String? {
        let page = plan.pages[index]
        guard plan.isSplit, page.startsDocument, let number = page.document else { return nil }
        return documentTitle(plan.documents[number - 1])
    }

    /// What a click on the gap before page `index` does: "Join with document 1" where a document
    /// starts, "Start a new document here" elsewhere; nil where it does nothing.
    public static func breakLabel(_ plan: SplitPlan, _ index: Int) -> String? {
        guard canToggleBreak(plan, index) else { return nil }
        let page = plan.pages[index]
        if page.startsDocument, let number = page.document { return "Join with document \(number - 1)" }
        return "Start a new document here"
    }

    /// The page strip's note on page `index`: "Separator" for a side of a separator sheet, otherwise
    /// `PageFilter.badge`.
    public static func badge(_ plan: SplitPlan, _ index: Int, page: ScannedPage, options: DocumentOptions) -> String? {
        plan.pages[index].role == .separator ? "Separator" : PageFilter.badge(page, options: options)
    }

    /// What one click on page `index` does: "Keep this page" for a separator page, otherwise
    /// `PageFilter.toggleLabel`.
    public static func toggleLabel(_ plan: SplitPlan, _ index: Int, page: ScannedPage, options: DocumentOptions) -> String? {
        plan.pages[index].role == .separator ? "Keep this page" : PageFilter.toggleLabel(page, options: options)
    }

    /// What a separator page is, for its help text and screen readers: "Separator sheet (Patch T): a
    /// new document starts after it. It is not saved." (the code when one was found); at barcode or QR
    /// sheets the sheet's code (read on either side) and the name of the document that follows as the
    /// plan names it (the last code sheet in a row names it, a name the user gives wins): "Separator
    /// sheet (QR code “CS-SEP Lease”): a new document named “Lease” starts after it. It is not saved.";
    /// when the user joined the page after the sheet to the document before: "Separator sheet (Patch
    /// T): the pages after it are joined to the document before. It is not saved."; nil for other pages.
    public static func separatorNote(_ plan: SplitPlan, _ index: Int, page: ScannedPage) -> String? {
        let planned = plan.pages[index]
        guard planned.role == .separator else { return nil }
        let what: String
        if let reading = planned.code {
            what = "Separator sheet (\(BarcodeSeparators.describe(reading)))"
        } else if let code = page.patch {
            what = "Separator sheet (\(code.label))"
        } else {
            what = "Blank separator sheet"
        }
        let next = nextSavedPage(plan, after: index)
        if let next = next, !next.startsDocument {
            return "\(what): the pages after it are joined to the document before. It is not saved."
        }
        if planned.code != nil, let number = next?.document, let name = plan.documents[number - 1].label {
            return "\(what): a new document named \u{201C}\(name)\u{201D} starts after it. It is not saved."
        }
        return "\(what): a new document starts after it. It is not saved."
    }

    /// The first page saved after `index`; nil when no page follows.
    private static func nextSavedPage(_ plan: SplitPlan, after index: Int) -> PlannedPage? {
        var i = index + 1
        while i < plan.pages.count {
            if plan.pages[i].document != nil { return plan.pages[i] }
            i += 1
        }
        return nil
    }

    /// "9 pages", "9 pages · 3 documents · 2 separator pages skipped", "24 pages · 5 blank skipped":
    /// `PageFilter.queueSummary` with documents and separators.
    public static func queueSummary(_ pages: [ScannedPage], options: DocumentOptions) -> String {
        let plan = self.plan(pages, options: options)
        let total = pages.count
        var text = "\(total) page\(total == 1 ? "" : "s")"
        if plan.isSplit { text += " \u{00B7} \(plan.documents.count) documents" }
        let separators = plan.separatorCount
        let skipped = pages.indices.filter { plan.pages[$0].role == .skipped }
        let allBlank = skipped.allSatisfy { PageFilter.looksBlank(pages[$0], sensitivity: options.blankSensitivity) }
        let skippedText = "\(skipped.count)\(allBlank ? " blank" : "")"
        let separatorText = "\(separators) separator page\(separators == 1 ? "" : "s")"
        if separators > 0 && !skipped.isEmpty { return "\(text) \u{00B7} \(separatorText) and \(skippedText) skipped" }
        if separators > 0 { return "\(text) \u{00B7} \(separatorText) skipped" }
        if !skipped.isEmpty { return "\(text) \u{00B7} \(skippedText) skipped" }
        return text
    }

    /// The status after a scan's pages were queued: " Found 2 separator pages: 3 documents to save."
    /// when the scan brought separator pages, " 3 documents to save." when the queue is split
    /// otherwise (leading space); empty when it is one document.
    public static func scanNote(_ plan: SplitPlan, separatorsAdded: Int) -> String {
        let documents = plan.documents.count
        let toSave = "\(documents) document\(documents == 1 ? "" : "s") to save."
        if separatorsAdded > 0 {
            return " Found \(separatorsAdded) separator page\(separatorsAdded == 1 ? "" : "s"): \(toSave)"
        }
        return plan.isSplit ? " \(toSave)" : ""
    }
}
