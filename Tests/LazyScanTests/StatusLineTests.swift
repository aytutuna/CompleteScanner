import XCTest
import CoreGraphics
import Foundation
@testable import LazyScanKit

// Mirrors windows/LazyScan.Core.Tests/StatusLineTests.cs: the status line's six words.

final class StatusLineTests: XCTestCase {

    func test_short_isShortAndFactual() {
        let cases: [(String, String)] = [
            ("Added 1 page \u{2014} 3 in queue. Scan more or Save PDF.", "Page 3 added"),
            ("Added 6 pages from 3 sheets, both sides \u{2014} 6 in queue. Scan more or Save PDF. 1 looks blank and will be skipped.",
             "6 pages added \u{00B7} 1 blank"),
            ("Added 2 pages \u{2014} 4 in queue. Scan more or Save PDF. 1 spread split into pages. Spine shadow softened on 2 pages.",
             "2 pages added \u{00B7} 1 spread split"),
            ("Saved 3-page PDF: Scan 2026-10-20 1.pdf (497.7 KB)", "Saved"),
            ("Saved 3 photos to /Users/me/files", "Saved 3 photos"),
            ("Found 3 photos on the bed.", "Found 3 photos"),
            ("Front scanned. Turn the card over where it lies and scan the back, or skip it.", "Front scanned"),
            ("Back scanned. Check the sides, then save.", "Back scanned"),
            ("Page queue cleared.", "Queue cleared"),
            ("Ready \u{2014} Demo Scanner", "Ready \u{2014} Demo Scanner"),
            ("Overview ready \u{2014} drag on the preview to select an area, then Scan.", "Overview ready"),
            ("Scanning\u{2026}", "Scanning\u{2026}"),
            ("Reading the text of page 3 of 12\u{2026}", "Reading page 3 of 12\u{2026}"),
            ("Adding 3 pages to Scan 2026-10-20 1.pdf\u{2026}", "Adding 3 pages\u{2026}"),
            ("Sent the ruler test page to Office Laser. At real size each square measures 1 inch.", "Sent to the printer"),
            ("9 pages \u{00B7} 3 documents.", "9 pages \u{00B7} 3 documents"),
            ("9 pages \u{00B7} 3 documents \u{00B7} 2 separator pages skipped.", "9 pages \u{00B7} 3 documents"),
            ("12 pages \u{00B7} 4 documents \u{00B7} 2 separator pages and 1 blank skipped.", "12 pages \u{00B7} 4 documents"),
            ("24 pages \u{00B7} 5 blank skipped.", "24 pages \u{00B7} 5 blank skipped"),
        ]
        for (message, expected) in cases {
            XCTAssertEqual(StatusLine.short(message), expected, message)
        }
    }

    func test_short_readyForATask_namesTheScannerInstead() {
        XCTAssertEqual(StatusLine.short("Ready for \u{201C}Document to PDF\u{201D}.", deviceName: "Demo Scanner"),
                       "Ready \u{2014} Demo Scanner")
        XCTAssertEqual(StatusLine.short("Ready for \u{201C}Document to PDF\u{201D}."), "Ready")
        XCTAssertEqual(StatusLine.short("   "), "")
    }

    func test_short_neverShowsMoreThanSixWords() {
        let messages: [String] = [
            "Could not connect to the Epson Perfection V600 Photo scanner over the network.",
            "Scanned 3 front sides before the feeder stopped. Load the rest of the stack and scan, or turn it over.",
            "The ID card task ended during the scan. Nothing of the card was kept.",
            "A very long message without any punctuation that goes on and on about nothing in particular",
        ]
        for message in messages {
            let shown = StatusLine.short(message)
            XCTAssertTrue((1...StatusLine.maxWords).contains(StatusLine.words(shown)), shown)
        }
    }

    func test_short_ofALongSentence_endsWithAnEllipsis() {
        XCTAssertEqual(StatusLine.short("A very long message without any punctuation that goes on and on about nothing in particular"),
                       "A very long message without any\u{2026}")
        XCTAssertEqual(StatusLine.short("Could not connect to the Epson Perfection V600 Photo scanner over the network."),
                       "Could not connect to the Epson\u{2026}")
        XCTAssertEqual(StatusLine.short("Scanned 3 front sides before the feeder stopped. Load the rest of the stack and scan, or turn it over."),
                       "Scanned 3 front sides before the\u{2026}")
    }

    /// The status after settings met a scanner, as the apps build it: the message, then each note.
    private func withNotes(_ message: String, _ settings: ScanSettings, _ capabilities: ScannerCapabilities) -> String {
        let notes: [SettingsNote] = SettingsAdapter.adapt(settings, to: capabilities).notes
        XCTAssertFalse(notes.isEmpty)
        return message + " " + notes.map(\.message).joined(separator: " ")
    }

    func test_short_keepsASettingChangedForTheScanner_asAShortWarning() {
        var six = ScanSettings()
        six.resolution = 600
        let lowResolution = ScannerCapabilities(supportedResolutions: [150, 300])
        // A preset at 600 dpi on a scanner that tops out at 300.
        let resolution = withNotes("Applied preset \u{201C}Invoices\u{201D}.", six, lowResolution)
        XCTAssertEqual(StatusLine.short(resolution), "Applied preset \u{201C}Invoices\u{201D} \u{00B7} 300 dpi used")
        // A longer preset name leaves no room: the warning wins.
        let longName = withNotes("Applied preset \u{201C}Monthly office invoices\u{201D}.", six, lowResolution)
        XCTAssertEqual(StatusLine.short(longName), "300 dpi used")
        // A scanner without a flatbed connects: no full stop before the note, and the name stays.
        var flatbedSettings = ScanSettings()
        flatbedSettings.source = .flatbed
        let feederOnly = ScannerCapabilities(sources: [.documentFeeder], feederSizeInches: CGSize(width: 8.5, height: 14))
        let feeder = withNotes("Ready \u{2014} Demo Scanner", flatbedSettings, feederOnly)
        XCTAssertEqual(StatusLine.short(feeder), "Ready \u{2014} Demo Scanner \u{00B7} feeder used")
        // A task is picked: "Ready — device" and the note.
        let picked = feeder.replacingOccurrences(of: "Ready \u{2014} Demo Scanner", with: "Ready for \u{201C}Document to PDF\u{201D}.")
        XCTAssertEqual(StatusLine.short(picked, deviceName: "Demo Scanner"), "Ready \u{2014} Demo Scanner \u{00B7} feeder used")
        var feederSettings = ScanSettings()
        feederSettings.source = .documentFeeder
        let flatbed = withNotes("Ready \u{2014} Demo Scanner", feederSettings, ScannerCapabilities(sources: [.flatbed]))
        XCTAssertEqual(StatusLine.short(flatbed), "Ready \u{2014} Demo Scanner \u{00B7} flatbed used")
        var legal = ScanSettings()
        legal.paperSize = .legal
        let paper = withNotes("Ready \u{2014} Demo Scanner", legal, ScannerCapabilities())
        XCTAssertEqual(StatusLine.short(paper), "Ready \u{2014} Demo Scanner \u{00B7} paper size Automatic")
        var both = ScanSettings()
        both.source = .documentFeeder
        both.duplex = .both
        let sides = withNotes("Ready \u{2014} Demo Scanner", both, feederOnly)
        XCTAssertEqual(StatusLine.short(sides), "Ready \u{2014} Demo Scanner \u{00B7} two-sided by hand")
        // Every note at once: as many as fit, then how many more.
        var everything = ScanSettings()
        everything.source = .flatbed
        everything.duplex = .both
        everything.paperSize = .legal
        everything.resolution = 600
        let small = ScannerCapabilities(supportedResolutions: [300], sources: [.documentFeeder],
                                        feederSizeInches: CGSize(width: 8.5, height: 11))
        let all = withNotes("Ready \u{2014} Demo Scanner", everything, small)
        XCTAssertEqual(StatusLine.short(all), "Feeder used \u{00B7} two-sided by hand +2")
        for message in [resolution, longName, feeder, picked, flatbed, paper, sides, all] {
            XCTAssertTrue((1...StatusLine.maxWords).contains(StatusLine.words(StatusLine.short(message, deviceName: "Demo Scanner"))))
        }
    }

    func test_short_aTwoSidedScanThatCameBackOneSided_saysSo() {
        XCTAssertEqual(StatusLine.short(
            "Added 3 pages, one side of each sheet: the scanner did not scan both sides \u{2014} 3 in queue. Scan more or Save PDF."),
                       "3 pages added \u{00B7} one side only")
        XCTAssertEqual(StatusLine.short(
            "Added 1 page, one side of each sheet: the scanner did not scan both sides \u{2014} 4 in queue. Scan more or Save PDF."),
                       "Page 4 added \u{00B7} one side only")
    }

    func test_words_countsTokensWithALetterOrDigit() {
        XCTAssertEqual(StatusLine.words("Ready \u{2014} Demo Scanner"), 3)
        XCTAssertEqual(StatusLine.words("6 pages added \u{00B7} 1 blank"), 5)
        XCTAssertEqual(StatusLine.words(" \u{2014} \u{00B7} "), 0)
    }

    func test_saved_withASettingChangedForTheScanner_keepsTheWarning() {
        // Capabilities read after a scan saved at once add their note to "Saved …".
        var high = ScanSettings()
        high.resolution = 1200
        let notes = SettingsAdapter.adapt(high, to: ScannerCapabilities(supportedResolutions: [300, 600])).notes
        let message = "Saved Scan 2026-10-20 1.pdf (412 KB) " + notes.map(\.message).joined(separator: " ")
        XCTAssertEqual(StatusLine.warnings(message), ["600 dpi used"])
        XCTAssertEqual(StatusLine.withWarnings("Saved", message: message), "Saved \u{00B7} 600 dpi used")
        XCTAssertEqual(StatusLine.short(message), "Saved \u{00B7} 600 dpi used")
        // Without a note, just the head.
        XCTAssertEqual(StatusLine.warnings("Saved Scan 2026-10-20 1.pdf (412 KB)"), [])
        XCTAssertEqual(StatusLine.withWarnings("Saved", message: "Saved Scan 2026-10-20 1.pdf (412 KB)"), "Saved")
        // Too many to fit with the head: the warnings win, as on any other line.
        var everything = ScanSettings()
        everything.source = .flatbed
        everything.duplex = .both
        everything.paperSize = .legal
        everything.resolution = 600
        let small = ScannerCapabilities(supportedResolutions: [300], sources: [.documentFeeder],
                                        feederSizeInches: CGSize(width: 8.5, height: 11))
        let all = SettingsAdapter.adapt(everything, to: small).notes
        let many = "Saved Scan 2026-10-20 1.pdf (412 KB) " + all.map(\.message).joined(separator: " ")
        let shown = StatusLine.withWarnings("Saved", message: many)
        XCTAssertEqual(StatusLine.short(many), shown)
        XCTAssertTrue((1...StatusLine.maxWords).contains(StatusLine.words(shown)))
    }

    func test_shown_isEmptyUnderAReview_andSavedWhileTheSavedFilesShow() {
        XCTAssertEqual(StatusLine.shown("Found 3 photos on the bed.", deviceName: "Demo Scanner", reviewShown: true, savedShown: false), "")
        XCTAssertEqual(StatusLine.shown("Back scanned. Check the sides, then save.", deviceName: "Demo Scanner",
                                        reviewShown: true, savedShown: false), "")
        XCTAssertEqual(StatusLine.shown("Saved 3-page PDF: Scan 2026-10-20 1.pdf (497.7 KB)", deviceName: nil,
                                        reviewShown: false, savedShown: true), "Saved")
        XCTAssertEqual(StatusLine.shown("Saved 3 photos to /Users/me/files", deviceName: nil, reviewShown: false, savedShown: true), "Saved")
        // Not about a save: the short line, whatever the saved files' actions.
        XCTAssertEqual(StatusLine.shown("Added 1 page \u{2014} 3 in queue. Scan more or Save PDF.", deviceName: nil,
                                        reviewShown: false, savedShown: true), "Page 3 added")
        XCTAssertEqual(StatusLine.shown("Ready for \u{201C}Photos\u{201D}.", deviceName: "Demo Scanner", reviewShown: false, savedShown: false),
                       "Ready \u{2014} Demo Scanner")
    }
}
