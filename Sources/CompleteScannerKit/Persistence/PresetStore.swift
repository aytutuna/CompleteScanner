import Foundation

// MARK: - PresetStore

public final class PresetStore {
    public init() {}

    /// Loads saved presets; on first run returns (and persists) built-in starter presets.
    public func load() -> [Preset] {
        if let presets = StoreFiles.read([Preset].self, from: StoreFiles.presetsURL) {
            return presets
        }
        let builtIns = PresetStore.builtInPresets()
        save(builtIns)
        return builtIns
    }

    public func save(_ presets: [Preset]) {
        StoreFiles.write(presets, to: StoreFiles.presetsURL)
    }

    // MARK: Built-in starter presets

    private static func builtInPresets() -> [Preset] {
        var documentPDF = ScanSettings()
        documentPDF.intent = .document
        documentPDF.resolution = 300
        documentPDF.colorMode = .color
        documentPDF.format = .pdf
        documentPDF.pdfSearchable = true
        documentPDF.documentMultiPage = true

        var compactText = ScanSettings()
        compactText.intent = .document
        compactText.resolution = 200
        compactText.colorMode = .grayscale
        compactText.format = .pdf
        compactText.pdfSearchable = true

        var photosJPEG = ScanSettings()
        photosJPEG.intent = .photo
        photosJPEG.resolution = 600
        photosJPEG.colorMode = .color
        photosJPEG.format = .jpeg
        photosJPEG.photoAutoSplit = true
        photosJPEG.photoAutoDeskew = true

        var photoRestoration = ScanSettings()
        photoRestoration.intent = .photo
        photoRestoration.resolution = 600
        photoRestoration.colorMode = .color
        photoRestoration.format = .png
        photoRestoration.adjustments.restoreFadedColors = true
        photoRestoration.adjustments.autoEnhance = true

        var quickPreview = ScanSettings()
        quickPreview.intent = .document
        quickPreview.resolution = 150
        quickPreview.colorMode = .color
        quickPreview.format = .jpeg
        quickPreview.documentMultiPage = false

        return [
            Preset(name: "Document → PDF (300 dpi)", settings: documentPDF),
            Preset(name: "Text document, compact (200 dpi, grayscale)", settings: compactText),
            Preset(name: "Photos → JPEG (600 dpi, auto-split)", settings: photosJPEG),
            Preset(name: "Old photo restoration (600 dpi, PNG)", settings: photoRestoration),
            Preset(name: "Quick preview scan (150 dpi)", settings: quickPreview),
        ]
    }
}

// MARK: - SettingsStore

public enum SettingsStore {
    public static func load() -> ScanSettings? {
        StoreFiles.read(ScanSettings.self, from: StoreFiles.settingsURL)
    }

    public static func save(_ settings: ScanSettings) {
        StoreFiles.write(settings, to: StoreFiles.settingsURL)
    }
}

// MARK: - Shared file plumbing

/// JSON storage under `~/Library/Application Support/CompleteScanner/` (created on demand).
private enum StoreFiles {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CompleteScanner", isDirectory: true)
    }

    static var presetsURL: URL { directory.appendingPathComponent("presets.json") }
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    /// nil when the file is missing or does not decode.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Best-effort atomic write; creates the directory on demand.
    static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
