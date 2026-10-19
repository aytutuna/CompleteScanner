import XCTest
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
