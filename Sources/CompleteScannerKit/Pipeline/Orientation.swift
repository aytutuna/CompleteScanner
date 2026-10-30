import Foundation

// Twin of windows/LazyScan.Core/Orientation.cs.

/// How much text recognition read on a page held one way up. Text read the right way up comes out
/// as words; upside down or sideways it comes out as few letters, or as letters that do not make
/// words ("suo!umqxa", "RTtnJqoed"). Twin of C# `OrientationScore`.
public struct OrientationScore: Equatable, Sendable {
    /// Letters and digits read, in every word.
    public let letters: Int
    /// Letters and digits in the words that look like words (`wordScore(_:)`).
    public let wordLetters: Int

    public init(letters: Int, wordLetters: Int) {
        self.letters = letters
        self.wordLetters = wordLetters
    }

    /// Nothing read.
    public static let none = OrientationScore(letters: 0, wordLetters: 0)

    /// The score of the lines text recognition read (words are split at white space).
    public static func of(_ lines: [String]) -> OrientationScore {
        var letters = 0
        var wordLetters = 0
        for line in lines {
            for word in line.split(whereSeparator: { $0.isWhitespace }) {
                letters += word.filter { isLetterOrDigit($0) }.count
                wordLetters += wordScore(String(word))
            }
        }
        return OrientationScore(letters: letters, wordLetters: wordLetters)
    }

    /// The letters of `word` when it looks like a word, else 0. Punctuation around it is left out;
    /// then it must be at least 2 long and be a number, or letters only (parts joined by hyphens or
    /// apostrophes) written in one case: lower case, capitals, a capital and then lower case, or a
    /// script without case. "Lieutenant," 10, "1903." 4, "Jean-Pierre" 10, "a.10Jaq" 0,
    /// "RTtnJqoed" 0, "o" 0.
    public static func wordScore(_ word: String) -> Int {
        let characters = Array(word)
        var start = 0
        var end = characters.count
        while start < end && !isLetterOrDigit(characters[start]) { start += 1 }
        while end > start && !isLetterOrDigit(characters[end - 1]) { end -= 1 }
        let core = Array(characters[start..<end])
        guard core.count >= 2 else { return 0 }
        if core.allSatisfy({ isDigit($0) }) { return core.count }
        var letters = 0
        for part in core.split(omittingEmptySubsequences: false, whereSeparator: { wordJoiners.contains($0) }) {
            guard !part.isEmpty, part.allSatisfy({ $0.isLetter }) else { return 0 }
            let upper = part.filter { $0.isUppercase }.count
            let lower = part.filter { $0.isLowercase }.count
            let oneCase = upper == 0 || lower == 0 || (upper == 1 && part[part.startIndex].isUppercase)
            guard oneCase else { return 0 }
            letters += part.count
        }
        return letters
    }

    /// The text reads well enough to be taken without trying the page another way up: at least
    /// `OrientationDecision.clearWordLetters` letters in words, and words make up at least
    /// `OrientationDecision.clearShare` of what was read.
    public var readsClearly: Bool {
        wordLetters >= OrientationDecision.clearWordLetters
            && Double(wordLetters) >= OrientationDecision.clearShare * Double(letters)
    }

    private static let wordJoiners: Set<Character> = ["-", "'", "\u{2019}"]

    /// A decimal digit (the twin of .NET `char.IsDigit`: Unicode category Nd).
    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isLetterOrDigit(_ character: Character) -> Bool {
        character.isLetter || isDigit(character)
    }
}

/// Reads text on a page image for `OrientationDecision`. The platform supplies it: Vision on the
/// Mac (`VisionOrientationScorer`), Windows OCR on Windows. Twin of C# `IOrientationScorer`.
public protocol OrientationScorer {
    /// Whether text can be read at all.
    var isAvailable: Bool { get }
    /// What text recognition reads on `image` as it is (the caller turns it). Throws when
    /// recognition fails.
    func score(_ image: RgbaImage) throws -> OrientationScore
}

/// What `OrientationDecision.check` found. Twin of C# `OrientationVerdict`.
public enum OrientationVerdict: Sendable {
    /// The page reads best as it is.
    case upright
    /// The page reads clearly better turned: `OrientationCheck.quarterTurns`.
    case turned
    /// No way up reads clearly better than the others (or text recognition failed): left as it is.
    case unsure
    /// Too little on the page to read: not read at all.
    case noText
    /// Reading took longer than the time a page may take: left as it is.
    case outOfTime
}

/// The score of the page turned `quarterTurns` quarter turns clockwise. Twin of C# `CandidateScore`.
public struct CandidateScore: Equatable, Sendable {
    public let quarterTurns: Int
    public let score: OrientationScore

    public init(quarterTurns: Int, score: OrientationScore) {
        self.quarterTurns = quarterTurns
        self.score = score
    }
}

/// What reading a page found: the verdict, the quarter turns clockwise that make the page upright
/// (0 unless `.turned`), every way up that was read with its score, in the order read, the page's
/// lines of text, and how long it took. Twin of C# `OrientationCheck`.
public struct OrientationCheck: Equatable, Sendable {
    public let verdict: OrientationVerdict
    public let quarterTurns: Int
    public let scores: [CandidateScore]
    public let layout: TextLayout
    public let seconds: Double

    /// How many times text recognition ran.
    public var passes: Int { scores.count }
}

/// Rotate pages upright: which way up a page reads, by text recognition. The lines of text on the
/// page (`DocumentGeometry.estimateTextLayout`) say which ways up are worth reading: across the
/// page, as it is or upside down; down the page, a quarter turn either way; not clear, all four.
/// Each is read once on a copy at most `analysisMaxSide` pixels long, the likeliest first; one that
/// reads clearly (`OrientationScore.readsClearly`) is taken at once when it is the page as it is, or
/// when the page was already read the opposite way up (turned 180° from it) and it has `margin` times
/// the letters in words of every way up read before it. Otherwise every way up worth reading is
/// read, and the one with the most letters in words wins when it has at least `minWordLetters` and
/// `margin` times as many as any other. A page that is blank, not clear, or takes longer than
/// `maxSecondsPerPage` is left as it is. Twin of C# `OrientationDecision`.
public enum OrientationDecision {
    /// The longest side of the copy that is read, in pixels.
    public static let analysisMaxSide = 1600
    /// The fewest letters in words that can turn a page.
    public static let minWordLetters = 20
    /// How many times the letters in words of any other way up the winner needs.
    public static let margin = 2.0
    /// Letters in words that read clearly enough to stop reading (`OrientationScore.readsClearly`).
    public static let clearWordLetters = 150
    /// The share of what was read that must be words to stop reading.
    public static let clearShare = 0.85
    /// The time one page may take; no new reading starts after it.
    public static let maxSecondsPerPage = 3.0

    /// The quarter turns clockwise worth reading, likeliest first: 0 and 2 for lines across the
    /// page, 1 and 3 for lines down it, all four (0, 2, 1, 3) when that is not clear, none when the
    /// page has too little ink to hold text (`DocumentGeometry.minInkPoints`).
    public static func candidates(_ layout: TextLayout) -> [Int] {
        guard layout.inkPoints >= DocumentGeometry.minInkPoints else { return [] }
        let sure = layout.confidence >= DocumentGeometry.minConfidence
        switch sure ? layout.axis : .unknown {
        case .horizontal: return [0, 2]
        case .vertical: return [1, 3]
        case .unknown: return [0, 2, 1, 3]
        }
    }

    /// The quarter turns of the way up that reads best, when it has at least `minWordLetters`
    /// letters in words and `margin` times as many as every other way up read; nil when none does
    /// (nothing read, or too close to call).
    public static func choose(_ scored: [CandidateScore]) -> Int? {
        guard !scored.isEmpty else { return nil }
        var bestIndex = 0
        for (index, candidate) in scored.enumerated()
        where candidate.score.wordLetters > scored[bestIndex].score.wordLetters {
            bestIndex = index
        }
        var runnerUp = 0
        for (index, candidate) in scored.enumerated() where index != bestIndex {
            runnerUp = max(runnerUp, candidate.score.wordLetters)
        }
        let top = scored[bestIndex].score.wordLetters
        return top >= minWordLetters && Double(top) >= margin * Double(runnerUp) ? scored[bestIndex].quarterTurns : nil
    }

    /// The size of the copy that is read: the image's own when no side is longer than `analysisMaxSide`.
    public static func analysisSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > analysisMaxSide else { return (width, height) }
        let scale = Double(analysisMaxSide) / Double(longest)
        // .NET Math.Round: halves to even.
        return (max(1, Int((Double(width) * scale).rounded(.toNearestOrEven))),
                max(1, Int((Double(height) * scale).rounded(.toNearestOrEven))))
    }

    /// The copy of `image` that is read (`analysisSize(width:height:)`).
    public static func analysisImage(_ image: RgbaImage) -> RgbaImage {
        let size = analysisSize(width: image.width, height: image.height)
        return image.resized(width: size.width, height: size.height)
    }

    /// Which way up `image` (scanned at `dpi`) reads (see the type's summary). `shouldContinue` is
    /// asked before every reading (`ScanError.cancelled` when it says no); `clock` (seconds; the
    /// system's uptime by default) times the page.
    public static func check(_ image: RgbaImage, dpi: Int, scorer: any OrientationScorer,
                             maxSeconds: Double = maxSecondsPerPage,
                             clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                             shouldContinue: () -> Bool = { true }) throws -> OrientationCheck {
        let start = clock()
        guard shouldContinue() else { throw ScanError.cancelled }
        let layout = DocumentGeometry.estimateTextLayout(GrayImage.from(image, sourceDPI: dpi))
        let turnsToRead = candidates(layout)
        var scores: [CandidateScore] = []
        func done(_ verdict: OrientationVerdict, _ turns: Int = 0) -> OrientationCheck {
            OrientationCheck(verdict: verdict, quarterTurns: turns, scores: scores, layout: layout,
                             seconds: clock() - start)
        }
        if turnsToRead.isEmpty { return done(.noText) }
        let analysis = analysisImage(image)
        for turns in turnsToRead {
            guard shouldContinue() else { throw ScanError.cancelled }
            if clock() - start > maxSeconds { return done(.outOfTime) }
            let score: OrientationScore
            do {
                score = try scorer.score(analysis.rotatedQuarterTurns(turns))
            } catch {
                // Recognition failed: nothing can be said about this page.
                return done(.unsure)
            }
            let earlier = scores.map { $0.score.wordLetters }.max() ?? 0
            let oppositeRead = scores.contains(where: { $0.quarterTurns == (turns + 2) % 4 })
            scores.append(CandidateScore(quarterTurns: turns, score: score))
            if score.readsClearly
                && (turns == 0 || (oppositeRead && Double(score.wordLetters) >= margin * Double(earlier))) {
                return turns == 0 ? done(.upright) : done(.turned, turns)
            }
        }
        switch choose(scores) {
        case nil: return done(.unsure)
        case 0?: return done(.upright)
        case let turns?: return done(.turned, turns)
        }
    }
}

/// What turning pages upright did to a page (`ScannedPage.upright`; kept only in the iPhone's queue record,
/// `QueueRecord`): the quarter turns clockwise it was turned (1 to 3), and whether the user turned it back.
/// Twin of C# `UprightTurn`.
public struct UprightTurn: Equatable, Codable, Sendable {
    public var quarterTurns: Int
    public var undone: Bool

    public init(quarterTurns: Int, undone: Bool = false) {
        self.quarterTurns = quarterTurns
        self.undone = undone
    }
}

/// What the page strip, the status and the inspector say about turning pages upright: a caption on
/// a turned page, its one-click undo, the note after a scan and the switch's hint. Twin of C# `PageTurns`.
public enum PageTurns {
    /// "Turned upright 180°", "Turned upright 90° clockwise" or "Turned upright 90° counterclockwise"
    /// for a turned page; "Turned back as scanned" once the user undid it; nil for other pages.
    public static func caption(_ page: ScannedPage) -> String? {
        guard let turn = page.upright else { return nil }
        if turn.undone { return "Turned back as scanned" }
        switch turn.quarterTurns {
        case 1: return "Turned upright 90° clockwise"
        case 3: return "Turned upright 90° counterclockwise"
        default: return "Turned upright 180°"
        }
    }

    /// What one click on the page's turn button does: "Undo turn" or "Turn upright again"; nil for a page not turned.
    public static func toggleLabel(_ page: ScannedPage) -> String? {
        guard let turn = page.upright else { return nil }
        return turn.undone ? "Turn upright again" : "Undo turn"
    }

    /// The status after the turn of a page was undone or made again: "Page 3 is turned back as
    /// scanned. It is saved that way." or "Page 3 is turned upright again."
    public static func toggleNote(_ page: ScannedPage, number: Int) -> String {
        if let turn = page.upright, !turn.undone { return "Page \(number) is turned upright again." }
        return "Page \(number) is turned back as scanned. It is saved that way."
    }

    /// The status after a scan's pages were queued, when some were turned: " 2 turned upright."
    /// (leading space; empty when none was).
    public static func scanNote(_ added: [ScannedPage]) -> String {
        let turned = added.filter { $0.upright?.undone == false }.count
        return turned == 0 ? "" : " \(turned) turned upright."
    }

    /// The status note when pages were to be turned upright but no text can be read (leading space).
    public static let unavailableNote = " Pages were not turned upright: no text recognition language is installed."

    /// The tooltip of "Rotate pages upright": why it is off for copies, receipts and scans saved at
    /// once, that it needs text recognition (shown next to it), else what it does.
    public static func hint(_ settings: ScanSettings, available: Bool) -> String {
        let flow = TaskCatalog.flow(of: settings)
        if flow == .copy { return "Copies print every page as scanned: pages are not turned." }
        if flow == .receiptSplit { return "Receipts are kept the way they lie on the glass." }
        if !settings.documentMultiPage { return "Only for pages collected before saving: a scan saved at once is kept as scanned." }
        if !available { return "Needs a text recognition language, and none is installed." }
        return "Turns sideways or upside-down pages by reading the text"
    }
}
