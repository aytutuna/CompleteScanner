import XCTest
import CoreGraphics
import Foundation
@testable import CompleteScannerKit

// Mirrors windows/CompleteScanner.Core.Tests/SettingsAdapterTests.cs: the same cases.

final class SettingsAdapterTests: XCTestCase {

    func test_noScanner_nothingChanges() {
        var settings = ScanSettings()
        settings.resolution = 450
        settings.source = .documentFeeder
        let adapted = SettingsAdapter.adapt(settings, to: nil)
        XCTAssertEqual(adapted.settings, settings)
        XCTAssertEqual(adapted.notes, [])
    }

    func test_supportedSettings_nothingChanges() {
        let caps = ScannerCapabilities(sources: [.flatbed, .documentFeeder])
        var settings = ScanSettings()
        settings.source = .documentFeeder
        let adapted = SettingsAdapter.adapt(settings, to: caps)
        XCTAssertEqual(adapted.settings.source, .documentFeeder)
        XCTAssertEqual(adapted.settings.resolution, 300)
        XCTAssertEqual(adapted.notes, [])
    }

    func test_resolution_nearestSupported() {
        let caps = ScannerCapabilities(supportedResolutions: [100, 200, 400, 800])
        var settings = ScanSettings()
        settings.resolution = 300
        let adapted = SettingsAdapter.adapt(settings, to: caps)
        // 300 is as near to 200 as to 400: the first listed wins, as before.
        XCTAssertEqual(adapted.settings.resolution, 200)
        XCTAssertEqual(adapted.notes, [SettingsNote(change: .resolution,
                                                    message: "This scanner does not offer 300 dpi, so 200 dpi is used.")])

        settings.resolution = 1200
        XCTAssertEqual(SettingsAdapter.adapt(settings, to: caps).settings.resolution, 800)
    }

    func test_resolution_noListedResolutions_kept() {
        let caps = ScannerCapabilities(supportedResolutions: [])
        var settings = ScanSettings()
        settings.resolution = 450
        let adapted = SettingsAdapter.adapt(settings, to: caps)
        XCTAssertEqual(adapted.settings.resolution, 450)
        XCTAssertEqual(adapted.notes, [])
    }

    func test_source_noFeeder_fallsBackToTheFlatbed() {
        let caps = ScannerCapabilities(sources: [.flatbed])
        var settings = ScanSettings()
        settings.source = .documentFeeder
        let adapted = SettingsAdapter.adapt(settings, to: caps)
        XCTAssertEqual(adapted.settings.source, .flatbed)
        XCTAssertEqual(adapted.notes, [SettingsNote(change: .source,
                                                    message: "This scanner has no document feeder, so the flatbed is used.")])
    }

    func test_source_noFlatbed_fallsBackToTheFeeder() {
        let caps = ScannerCapabilities(sources: [.documentFeeder], supportsOverview: false)
        let adapted = SettingsAdapter.adapt(ScanSettings(), to: caps)
        XCTAssertEqual(adapted.settings.source, .documentFeeder)
        XCTAssertEqual(adapted.notes.map(\.message), ["This scanner has no flatbed, so the document feeder is used."])
    }

    func test_source_noSourcesListed_flatbed() {
        let caps = ScannerCapabilities(sources: [])
        var settings = ScanSettings()
        settings.source = .documentFeeder
        let feeder = SettingsAdapter.adapt(settings, to: caps)
        XCTAssertEqual(feeder.settings.source, .flatbed)
        XCTAssertEqual(feeder.notes.count, 1)
        // Already the flatbed: nothing to say.
        XCTAssertEqual(SettingsAdapter.adapt(ScanSettings(), to: caps).notes, [])
    }

    func test_bothChanges_sourceFirst() {
        let caps = ScannerCapabilities(supportedResolutions: [150, 300], sources: [.flatbed])
        var settings = ScanSettings()
        settings.source = .documentFeeder
        settings.resolution = 1200
        let adapted = SettingsAdapter.adapt(settings, to: caps)
        XCTAssertEqual(adapted.notes.map(\.change), [.source, .resolution])
        XCTAssertEqual(adapted.settings.source, .flatbed)
        XCTAssertEqual(adapted.settings.resolution, 300)
    }

    func test_everythingElseIsKept() {
        var settings = ScanSettings()
        settings.intent = .photo
        settings.source = .documentFeeder
        settings.resolution = 600
        settings.colorMode = .grayscale
        settings.format = .tiff
        settings.destinationPath = "/Users/someone/Scans"
        settings.adjustments.contrast = 1.5
        settings.taskId = "photos"
        let caps = ScannerCapabilities(supportedResolutions: [300], sources: [.flatbed])

        let adapted = SettingsAdapter.adapt(settings, to: caps)

        var expected = settings
        expected.source = .flatbed
        expected.resolution = 300
        XCTAssertEqual(adapted.settings, expected)
    }

    // MARK: Two-sided scanning and paper size

    private func feederScanner(duplex: Bool, feederSize: CGSize? = nil) -> ScannerCapabilities {
        ScannerCapabilities(sources: [.flatbed, .documentFeeder], feederSizeInches: feederSize, supportsDuplex: duplex)
    }

    func test_duplex_oneSidedFeeder_turnsTheStackOverByHand() {
        var settings = ScanSettings()
        settings.source = .documentFeeder
        settings.duplex = .both
        let adapted = SettingsAdapter.adapt(settings, to: feederScanner(duplex: false))
        XCTAssertEqual(adapted.settings.duplex, .manual)
        XCTAssertEqual(adapted.notes, [SettingsNote(change: .duplex,
                                                    message: "This scanner's feeder scans one side at a time, so you'll turn the stack over by hand.")])
    }

    func test_duplex_twoSidedFeeder_orTheFlatbed_nothingChanges() {
        var feeder = ScanSettings()
        feeder.source = .documentFeeder
        feeder.duplex = .both
        var adapted = SettingsAdapter.adapt(feeder, to: feederScanner(duplex: true))
        XCTAssertEqual(adapted.settings.duplex, .both)
        XCTAssertEqual(adapted.notes, [])

        // The setting does nothing on the flatbed: it is kept for the feeder.
        var flatbed = ScanSettings()
        flatbed.duplex = .both
        adapted = SettingsAdapter.adapt(flatbed, to: feederScanner(duplex: false))
        XCTAssertEqual(adapted.settings.duplex, .both)
        XCTAssertEqual(adapted.notes, [])

        var byHand = ScanSettings()
        byHand.source = .documentFeeder
        byHand.duplex = .manual
        XCTAssertEqual(SettingsAdapter.adapt(byHand, to: feederScanner(duplex: false)).notes, [])
    }

    func test_duplex_afterFallingBackToTheFeeder() {
        let caps = ScannerCapabilities(sources: [.documentFeeder], supportsOverview: false)
        var settings = ScanSettings()
        settings.duplex = .both
        let adapted = SettingsAdapter.adapt(settings, to: caps)
        XCTAssertEqual(adapted.settings.source, .documentFeeder)
        XCTAssertEqual(adapted.settings.duplex, .manual)
        XCTAssertEqual(adapted.notes.map(\.change), [.source, .duplex])
    }

    func test_paperSize_largerThanTheGlass_isAutomatic() {
        let caps = ScannerCapabilities(flatbedSizeInches: CGSize(width: 8.5, height: 11.7))
        var settings = ScanSettings()
        settings.paperSize = .legal
        let adapted = SettingsAdapter.adapt(settings, to: caps)
        XCTAssertEqual(adapted.settings.paperSize, .auto)
        XCTAssertEqual(adapted.notes, [SettingsNote(change: .paperSize,
                                                    message: "Legal paper does not fit this scanner's glass, so the paper size is Automatic.")])
        settings.paperSize = .a4
        XCTAssertEqual(SettingsAdapter.adapt(settings, to: caps).settings.paperSize, .a4)
    }

    func test_paperSize_largerThanTheFeeder_isAutomatic_unknownFeederSizeKeepsIt() {
        var settings = ScanSettings()
        settings.source = .documentFeeder
        settings.paperSize = .legal
        let adapted = SettingsAdapter.adapt(settings, to: feederScanner(duplex: true, feederSize: CGSize(width: 8.5, height: 11)))
        XCTAssertEqual(adapted.settings.paperSize, .auto)
        XCTAssertEqual(adapted.notes.map(\.message),
                       ["Legal paper does not fit this scanner's feeder, so the paper size is Automatic."])
        XCTAssertEqual(SettingsAdapter.adapt(settings, to: feederScanner(duplex: true, feederSize: CGSize(width: 8.5, height: 14)))
                        .settings.paperSize, .legal)
        XCTAssertEqual(SettingsAdapter.adapt(settings, to: feederScanner(duplex: true)).settings.paperSize, .legal)
    }

    func test_twoSidedTask_onAOneSidedFeeder_stillFits() {
        let adapted = SettingsAdapter.adapt(TaskCatalog.apply(.twoSided, to: ScanSettings()), to: feederScanner(duplex: false))
        XCTAssertEqual(adapted.settings.duplex, .manual)
        XCTAssertTrue(TaskCatalog.fits(.twoSided, adapted.settings))
    }

    func test_twoSidedTask_whileTheFeederIsNotYetAsked_keepsBothSides() {
        // ImageCaptureCore tells whether the feeder scans both sides only once it is selected.
        let unknown = DocumentSides.capabilitiesForSides(feederScanner(duplex: false), duplexKnown: false)
        let task = TaskCatalog.apply(.twoSided, to: ScanSettings())
        let adapted = SettingsAdapter.adapt(task, to: unknown)
        XCTAssertEqual(adapted.settings.duplex, .both)
        XCTAssertEqual(adapted.notes, [])
        XCTAssertEqual(TaskCatalog.summary(adapted.settings), "300 dpi \u{00B7} Color \u{00B7} PDF \u{00B7} Both sides")
        XCTAssertNil(TaskCatalog.guidedSteps(adapted.settings, capabilities: unknown)?
            .first(where: { $0.id == DocumentSides.backsStepID }))
    }

    func test_taskSettings_onAFeederOnlyScanner() {
        let caps = ScannerCapabilities(supportedResolutions: [150, 300, 600], sources: [.documentFeeder],
                                       supportsOverview: false)
        let photos = SettingsAdapter.adapt(TaskCatalog.apply(.photos, to: ScanSettings()), to: caps).settings
        XCTAssertEqual(photos.source, .documentFeeder)
        XCTAssertTrue(TaskCatalog.fits(.photos, photos))
        let quick = SettingsAdapter.adapt(TaskCatalog.apply(.quickScan, to: ScanSettings()), to: caps).settings
        XCTAssertFalse(TaskCatalog.fits(.quickScan, quick))
    }
}
