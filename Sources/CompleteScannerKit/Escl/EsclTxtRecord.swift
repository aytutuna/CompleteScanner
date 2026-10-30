import Foundation

// Twin of windows/LazyScan.Core/Escl/EsclTxtRecord.cs: the same keys, defaults and UUID key.

/// The TXT record a network scanner advertises with its _uscan._tcp / _uscans._tcp DNS-SD service
/// (Mopria eSCL): where the eSCL resource lives, what the device is and roughly what it can do, known
/// before connecting to it.
public struct EsclTxtRecord: Equatable, Sendable {
    /// The eSCL resource path below the host, without slashes ("eSCL" unless the device says
    /// otherwise; "" for the root).
    public var resourcePath: String = "eSCL"
    /// Make and model (ty), e.g. "HP Color LaserJet MFP M479fdw".
    public var model: String?
    /// The device UUID (UUID), the same value its ScannerCapabilities report.
    public var uuid: String?
    /// The device's web page (adminurl).
    public var adminUrl: String?
    /// eSCL version (vers), e.g. "2.63".
    public var version: String?
    /// The user-assigned location (note).
    public var note: String?
    /// The feeder scans both sides (duplex=T); nil when not advertised.
    public var duplex: Bool?
    /// Input sources (is), lowercased, e.g. "platen", "adf".
    public var inputSources: [String] = []
    /// Color spaces (cs), lowercased, e.g. "color", "grayscale", "binary".
    public var colorSpaces: [String] = []
    /// Document formats (pdl), e.g. "image/jpeg", "application/pdf".
    public var documentFormats: [String] = []

    public init() {}

    /// Reads "key=value" strings (the form the system reports TXT attributes in). Keys are matched
    /// without regard to ASCII case and only the first occurrence of a key counts (RFC 6763, 6.4);
    /// entries without '=' and unknown keys are ignored.
    public static func parse(_ attributes: [String]?) -> EsclTxtRecord {
        var values: [String: String] = [:]
        for attribute in attributes ?? [] {
            guard let equals = attribute.firstIndex(of: "="), equals > attribute.startIndex else { continue }
            let key: String = String(attribute[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String = String(attribute[attribute.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let folded: String = key.lowercased()
            if !key.isEmpty && values[folded] == nil {
                values[folded] = value
            }
        }

        var record = EsclTxtRecord()
        // A present but empty rs means the resource is at the root.
        if let rs = values["rs"] {
            record.resourcePath = rs.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        record.model = nonEmpty(values["ty"])
        record.uuid = nonEmpty(values["uuid"])
        record.adminUrl = nonEmpty(values["adminurl"])
        record.version = nonEmpty(values["vers"])
        record.note = nonEmpty(values["note"])
        switch nonEmpty(values["duplex"])?.uppercased() ?? "" {
        case "T", "TRUE": record.duplex = true
        case "F", "FALSE": record.duplex = false
        default: record.duplex = nil
        }
        record.inputSources = list(values["is"], lowercase: true)
        record.colorSpaces = list(values["cs"], lowercase: true)
        record.documentFormats = list(values["pdl"], lowercase: false)
        return record
    }

    /// A UUID reduced to its lowercase letters and digits ("urn:uuid:" and braces dropped), so the
    /// forms devices use in TXT records and capabilities compare equal; nil when empty.
    public static func uuidKey(_ uuid: String?) -> String? {
        guard let uuid = uuid else { return nil }
        var text: String = uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty {
            return nil
        }
        let prefix: String = "urn:uuid:"
        if text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        var key: String = ""
        for scalar in text.unicodeScalars {
            let value: UInt32 = scalar.value
            let isDigit: Bool = value >= 0x30 && value <= 0x39
            let isLower: Bool = value >= 0x61 && value <= 0x7A
            let isUpper: Bool = value >= 0x41 && value <= 0x5A
            if isDigit || isLower || isUpper {
                key.unicodeScalars.append(scalar)
            }
        }
        return key.isEmpty ? nil : key
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty else { return nil }
        return value
    }

    /// A comma-separated value: trimmed items, empty ones dropped, duplicates (ignoring case) dropped.
    private static func list(_ value: String?, lowercase: Bool) -> [String] {
        guard let text = nonEmpty(value) else { return [] }
        var items: [String] = []
        var seen: Set<String> = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            var item: String = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty {
                continue
            }
            if lowercase {
                item = item.lowercased()
            }
            let folded: String = item.uppercased()
            if !seen.contains(folded) {
                seen.insert(folded)
                items.append(item)
            }
        }
        return items
    }
}
