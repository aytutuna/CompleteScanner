import Foundation

// Twin of windows/LazyScan.Core/DeviceMerge.cs; the tests in DeviceMergeTests (both
// platforms) share one table of cases.

/// One physical scanner: every entry the backends list for it, and the one the app connects
/// through. `key` identifies the scanner across runs (it keys a connection choice) and is
/// unique within one grouping.
public struct DeviceGroup: Equatable, Sendable {
    public let key: String
    public let primary: ScannerInfo
    /// All entries for the scanner, in the order the backends listed them.
    public let members: [ScannerInfo]

    public init(key: String, primary: ScannerInfo, members: [ScannerInfo]) {
        self.key = key
        self.primary = primary
        self.members = members
    }
}

/// Merges the entries several backends list for the same scanner (USB and Bonjour on macOS;
/// WIA, TWAIN and eSCL on Windows) into one `DeviceGroup`, and picks the connection to use.
public enum DeviceMerge {
    /// Windows connection ranking, best first: WIA, then eSCL, then TWAIN.
    public static let windowsRanking = ["wia:WIA", "escl:Network", "wia:*", "twain:*"]

    /// macOS connection ranking, best first: USB, then Bonjour, then shared scanners.
    public static let macRanking = ["ic:USB", "ic:Network", "ic:Shared"]

    /// iPhone and iPad connection ranking, best first: the scanner's own network connection (eSCL),
    /// then a computer's scanner reached through the desktop companion. Windows never uses it.
    public static let iosRanking = ["escl:Network", "companion:*"]

    /// Words that say how a device is reached, or what kind of thing it is, rather than which model it is.
    private static let stopWords: Set<String> = [
        "wia", "twain", "tw", "driver", "scanner", "scan", "series", "usb", "network", "net", "wsd",
        "escl", "airscan", "ds", "x64", "x86", "64bit", "32bit", "inc", "corp", "corporation", "co", "ltd",
    ]

    /// Text in round, square or curly brackets: "(USB)", "[192.168.1.5]", "{TWAIN}".
    private static let bracketed = makeRegex(#"\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}"#)

    /// An IPv4 address, with an optional port.
    private static let ipv4 = makeRegex(#"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?::[0-9]{1,5})?(?![0-9.])"#)

    /// An IPv6 address (at least two colons), with an optional zone.
    private static let ipv6 = makeRegex(#"(?<![0-9a-z:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:%[0-9a-z]+)?(?![0-9a-z:])"#)

    /// "64-bit", "32 bit", "64bit": a driver build, not part of the model number.
    private static let bitWidth = makeRegex(#"(?<![0-9a-z])(?:32|64)[ -]?bit(?![0-9a-z])"#)

    /// The model words of a device name, normalized so the names different drivers give the
    /// same scanner compare equal: ASCII-lowercased; bracketed text, IP addresses and bit
    /// widths removed; split on everything but a–z and 0–9; vendor aliases mapped (Hewlett /
    /// Packard → hp, Seiko Epson → epson, Kodak Alaris → kodak); connection and filler words
    /// dropped; repeated words kept once. The words are joined by single spaces.
    public static func modelKey(_ name: String) -> String {
        modelTokens(name).joined(separator: " ")
    }

    private static func modelTokens(_ name: String) -> [String] {
        var text = asciiLowercased(name)
        for pattern in [bracketed, ipv4, ipv6, bitWidth] {
            text = replacingMatches(of: pattern, in: text)
        }

        var raw: [String] = []
        var word = ""
        for scalar in text.unicodeScalars {
            if isASCIIAlphanumeric(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                raw.append(word)
                word = ""
            }
        }
        if !word.isEmpty { raw.append(word) }

        var tokens: [String] = []
        for index in raw.indices {
            var token = raw[index]
            if token == "hewlett" || token == "packard" {
                token = "hp"
            } else if token == "seiko" && index + 1 < raw.count && raw[index + 1] == "epson" {
                continue
            } else if token == "alaris" && index > 0 && raw[index - 1] == "kodak" {
                continue
            }
            if stopWords.contains(token) || tokens.contains(token) { continue }
            tokens.append(token)
        }
        return tokens
    }

    /// Whether two entries are the same physical scanner. Demo devices match nothing. Two
    /// entries from the same backend over the same transport never match, so two identical
    /// scanners stay apart. When both have a hardware id, the ids decide. Otherwise the model
    /// words (`modelKey`) of the entries' model or name — any pairing of the two, since some
    /// drivers report a generic description and some names are user-chosen — must be equal,
    /// or one set must contain the other while sharing at least two words, one of them with
    /// a digit (the model number).
    public static func sameDevice(_ a: ScannerInfo, _ b: ScannerInfo) -> Bool {
        if a.isDemo || b.isDemo { return false }
        if asciiLowercased(a.backend) == asciiLowercased(b.backend)
            && asciiLowercased(a.transport) == asciiLowercased(b.transport) {
            return false
        }
        if let idA = normalizedHardwareID(a.hardwareID), let idB = normalizedHardwareID(b.hardwareID) {
            return idA == idB
        }

        for nameA in namesOf(a) {
            for nameB in namesOf(b) where sameModelWords(modelTokens(nameA), modelTokens(nameB)) {
                return true
            }
        }
        return false
    }

    private static func sameModelWords(_ tokensA: [String], _ tokensB: [String]) -> Bool {
        let wordsA = Set(tokensA)
        let wordsB = Set(tokensB)
        if wordsA.isEmpty || wordsB.isEmpty { return false }
        if wordsA == wordsB { return true }
        if !wordsA.isSubset(of: wordsB) && !wordsB.isSubset(of: wordsA) { return false }
        let shared = wordsA.intersection(wordsB)
        return shared.count >= 2 && shared.contains(where: { token in hasDigit(token) })
    }

    /// Groups the entries of all backends into one `DeviceGroup` per scanner, in the order the
    /// scanners first appear. An entry joins the first group whose every member is the
    /// `sameDevice`. The primary is the member whose connection (`connectionID`) `overrides`
    /// names for the group's key, when that member is present; otherwise the member matching
    /// the earliest of `rankPatterns` ("backend:transport", "*" matches any text, ASCII case
    /// ignored), the earliest listed among equals.
    public static func group(_ devices: [ScannerInfo], rankPatterns: [String],
                             overrides: [String: String] = [:]) -> [DeviceGroup] {
        var clusters: [[ScannerInfo]] = []
        for device in devices {
            if let index = clusters.firstIndex(where: { cluster in
                cluster.allSatisfy { member in sameDevice(member, device) }
            }) {
                clusters[index].append(device)
            } else {
                clusters.append([device])
            }
        }

        var groups: [DeviceGroup] = []
        var usedKeys = Set<String>()
        for members in clusters {
            let baseKey = groupKey(members)
            var key = baseKey
            var suffix = 2
            while !usedKeys.insert(key).inserted {
                key = "\(baseKey)#\(suffix)"
                suffix += 1
            }

            var primary: ScannerInfo?
            if let chosen = overrides[key] {
                let wanted = asciiLowercased(chosen)
                primary = members.first(where: { member in asciiLowercased(connectionID(member)) == wanted })
            }
            groups.append(DeviceGroup(key: key,
                                      primary: primary ?? bestRanked(members, rankPatterns: rankPatterns),
                                      members: members))
        }
        return groups
    }

    /// The connection an entry stands for: "backend:transport", e.g. "ic:USB" or "wia:WIA".
    public static func connectionID(_ device: ScannerInfo) -> String {
        "\(device.backend):\(device.transport)"
    }

    /// A short name for an entry's connection, for a connection chooser.
    public static func connectionLabel(_ device: ScannerInfo) -> String {
        switch asciiLowercased(device.backend) {
        case "wia": return "WIA"
        case "twain": return "TWAIN"
        case "escl": return "Network (eSCL)"
        case "mock": return "Demo"
        default: return device.transport
        }
    }

    /// The grouping spelled out, one line per group and one per member with the raw names and
    /// the model key each matched on, for a diagnostics file: real driver names show which
    /// aliases and stop words are still missing.
    public static func diagnosticsReport(_ groups: [DeviceGroup]) -> String {
        var text = ""
        for group in groups {
            text += "\(group.key) -> \(connectionID(group.primary)) \"\(group.primary.id)\"\n"
            for m in group.members {
                text += "  \(connectionID(m)) id=\"\(m.id)\" name=\"\(m.name)\" model=\"\(m.model ?? "")\" "
                    + "hardwareId=\"\(m.hardwareID ?? "")\" key=\"\(modelKey(matchName(m)))\"\n"
            }
        }
        return text
    }

    // MARK: - Private

    /// A key that stays the same while the scanner's set of connections changes: its hardware
    /// id when a member has one, otherwise the shortest model key among the members (the
    /// alphabetically first among equals), otherwise the first member's id. Demo devices are
    /// keyed by id.
    private static func groupKey(_ members: [ScannerInfo]) -> String {
        if members.contains(where: { member in member.isDemo }) { return "device:" + members[0].id }
        for member in members {
            if let id = normalizedHardwareID(member.hardwareID) { return "id:" + id }
        }
        var best: String?
        var bestCount = Int.max
        for member in members {
            let tokens = modelTokens(matchName(member))
            if tokens.isEmpty { continue }
            let key = tokens.joined(separator: " ")
            let better: Bool
            if let current = best {
                better = tokens.count < bestCount || (tokens.count == bestCount && key < current)
            } else {
                better = true
            }
            if better {
                best = key
                bestCount = tokens.count
            }
        }
        if let best { return "model:" + best }
        return "device:" + members[0].id
    }

    /// The member matching the earliest pattern; the first listed among equals.
    private static func bestRanked(_ members: [ScannerInfo], rankPatterns: [String]) -> ScannerInfo {
        var best = members[0]
        var bestRank = rank(best, rankPatterns)
        for member in members.dropFirst() {
            let memberRank = rank(member, rankPatterns)
            if memberRank < bestRank {
                best = member
                bestRank = memberRank
            }
        }
        return best
    }

    private static func rank(_ device: ScannerInfo, _ patterns: [String]) -> Int {
        let connection = connectionID(device)
        for (index, pattern) in patterns.enumerated() where globMatches(pattern, connection) {
            return index
        }
        return patterns.count
    }

    /// "*" matches any run of characters, including none; other characters match themselves,
    /// ASCII case ignored. Compares UTF-16 code units, like the C# twin.
    private static func globMatches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(asciiLowercased(pattern).utf16)
        let t = Array(asciiLowercased(text).utf16)
        let star = UInt16(UInt8(ascii: "*"))
        var pi = 0
        var ti = 0
        var starIndex = -1
        var mark = 0
        while ti < t.count {
            if pi < p.count && p[pi] == star {
                starIndex = pi
                pi += 1
                mark = ti
            } else if pi < p.count && p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if starIndex >= 0 {
                pi = starIndex + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == star { pi += 1 }
        return pi == p.count
    }

    /// The text an entry is keyed on: its model when known, otherwise its name.
    private static func matchName(_ device: ScannerInfo) -> String {
        if let model = device.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model
        }
        return device.name
    }

    /// The texts an entry is matched on: its model when known, then its name.
    private static func namesOf(_ device: ScannerInfo) -> [String] {
        if let model = device.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [model, device.name]
        }
        return [device.name]
    }

    /// A hardware id reduced to lowercase letters and digits ("urn:uuid:" dropped); nil when there is none.
    private static func normalizedHardwareID(_ id: String?) -> String? {
        guard let id = id else { return nil }
        var text = asciiLowercased(id.trimmingCharacters(in: .whitespacesAndNewlines))
        let prefix = "urn:uuid:"
        if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        var kept = ""
        for scalar in text.unicodeScalars where isASCIIAlphanumeric(scalar) {
            kept.unicodeScalars.append(scalar)
        }
        return kept.isEmpty ? nil : kept
    }

    private static func hasDigit(_ token: String) -> Bool {
        token.unicodeScalars.contains(where: { scalar in scalar.value >= 48 && scalar.value <= 57 })
    }

    /// a–z or 0–9 (the text is already ASCII-lowercased).
    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
    }

    /// A–Z lowered to a–z; every other character unchanged (the same on every platform and locale).
    private static func asciiLowercased(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar.value >= 65 && scalar.value <= 90 {
                result.unicodeScalars.append(Unicode.Scalar(UInt8(scalar.value + 32)))
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func replacingMatches(of regex: NSRegularExpression, in text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid built-in pattern \(pattern): \(error)")
        }
    }
}
