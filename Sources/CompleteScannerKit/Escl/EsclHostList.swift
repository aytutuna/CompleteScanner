import Foundation

// Twin of windows/CompleteScanner.Core/Escl/EsclHostList.cs: the same file (escl-hosts.json, a JSON
// list of address strings) and rules; each platform keeps its own in its own settings folder.

/// The network scanners added by address: escl-hosts.json in the settings folder, a JSON list of
/// address strings (["192.168.1.50", "scanner.local:8080", "https://10.0.0.7"]). Adding a scanner by
/// address writes it, and entries written by hand keep working. Entries that do not parse as an
/// address are kept but not used. The file follows the settings-file rules (CONTRACTS.md, rule 6): a
/// file that does not decode is kept aside as escl-hosts.unreadable-<timestamp>.json, one that cannot
/// be read is never overwritten.
public final class EsclHostList {
    public static let fileName = "escl-hosts.json"

    public let fileURL: URL

    public convenience init() {
        self.init(directory: StoreFiles.defaultDirectory)
    }

    /// Keeps escl-hosts.json in `directory` (tests).
    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(EsclHostList.fileName)
    }

    /// The entries as written, in order; empty when there is no file or it could not be loaded.
    public func loadEntries() -> [String] {
        StoreFiles.load([String].self, from: fileURL) ?? []
    }

    /// The usable addresses, in order, without duplicates.
    public func load() -> [ScannerAddress] {
        var addresses: [ScannerAddress] = []
        for entry in loadEntries() {
            var error: String = ""
            if let address = ScannerAddress.tryParse(entry, error: &error), !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }

    /// Adds `address` in its canonical form; false when it is already listed.
    @discardableResult
    public func add(_ address: ScannerAddress) -> Bool {
        var entries: [String] = loadEntries()
        for entry in entries where EsclHostList.matches(entry, address) {
            return false
        }
        entries.append(address.description)
        StoreFiles.write(entries, to: fileURL)
        return true
    }

    /// Removes every entry meaning `address`; false when none did.
    @discardableResult
    public func remove(_ address: ScannerAddress) -> Bool {
        let entries: [String] = loadEntries()
        var kept: [String] = []
        for entry in entries where !EsclHostList.matches(entry, address) {
            kept.append(entry)
        }
        if kept.count == entries.count {
            return false
        }
        StoreFiles.write(kept, to: fileURL)
        return true
    }

    private static func matches(_ entry: String, _ address: ScannerAddress) -> Bool {
        var error: String = ""
        guard let parsed = ScannerAddress.tryParse(entry, error: &error) else { return false }
        return parsed == address
    }
}
