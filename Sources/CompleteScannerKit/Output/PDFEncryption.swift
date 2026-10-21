import CommonCrypto
import CryptoKit
import Foundation
import Security

// Twin of windows/CompleteScanner.Core/PdfEncryption.cs (PasswordStrength, PdfProtection,
// PdfEncryption): the same password preparation, strength guess and texts, and the same standard
// security handler (V5 R6, AES-256) with the same values for the same random bytes, so a protected
// file is the same file on both platforms (PDFEncryptionTests' golden values, pinned in C#). AES is
// CommonCrypto's (CryptoKit has no AES-CBC), SHA-256/384/512 CryptoKit's and the random bytes
// `SecRandomCopyBytes`'; all three are system frameworks on macOS and iOS. C#'s exceptions
// (argument, disposed, cryptographic) are `ScanError.exportFailed` here.

/// How hard a password looks to guess (`PDFProtection.strengthOf`). The first case is the default.
public enum PasswordStrength: String, CaseIterable, Sendable {
    /// No password typed yet.
    case none
    case weak
    case fair
    case strong
}

/// The password a PDF is protected with and what a PDF app may let its reader do once the file is
/// open. Made at save time from what the user typed and used for that save only: the password is
/// never stored (settings keep only `OutputOptions.protect`), and `dispose()` wipes its prepared
/// bytes. The texts of the password option and its dialog are here too. Twin of C# `PdfProtection`.
/// It goes along to the task that writes the PDFs, and nothing changes it while one is written.
public final class PDFProtection: @unchecked Sendable {
    /// A password is at most this many bytes once prepared; readers cut a longer one the same way.
    public static let maxPasswordBytes = 127

    /// The password switch in the inspector's Archive & password section.
    public static let optionLabel = "Require a password"

    /// What the switch does, on hover.
    public static let optionHint = "PDFs open only with the password. You type it when saving."

    /// What the switch does, for screen readers: the hover text with what can't be undone.
    public static let optionHelp =
        "Saved PDFs open only with a password. You type it each time you save: it is never stored, and a forgotten password can't be recovered."

    /// Why the switch is greyed out while archival PDF (PDF/A) is on, shown next to it.
    public static let notWithArchivalReason = "Not with PDF/A"

    /// The dialog's title and heading.
    public static let dialogTitle = "Set a PDF password"

    /// The warning the dialog shows under its heading: what can't be undone, and that it applies to
    /// every save from now on.
    public static let dialogMessage = "It can't be recovered if forgotten. Every PDF you save now gets it."

    /// The dialog's whole explanation, for screen readers.
    public static let dialogHelp =
        "Anyone who opens the file will need this password. It isn't saved anywhere, and it can't be recovered if it's forgotten. Every PDF saved now gets it."

    /// The permissions are requests that PDF apps honor, not locks; the dialog says so (on hover and
    /// for screen readers).
    public static let permissionsNote =
        "Most PDF apps respect these choices, but they are a request, not a lock: someone with the password can get around them with other software."

    /// The line under the permissions: short, and always shown, so they are not taken for a lock.
    public static let permissionsShortNote = "Some apps ignore these settings."

    /// The status when a save that needs a password got none (the dialog was cancelled).
    public static let notSavedMessage = "Not saved: no password was given for the protected PDF."

    /// The status when pages saved as they were scanned got no password: they wait in the queue.
    public static func keptInQueueMessage(_ pages: Int) -> String {
        let what: String = pages == 1 ? "page is" : "\(pages) pages are"
        return "Not saved: no password was given for the protected PDF. The \(what) in the queue: save with a password, or turn the password off."
    }

    private var prepared: [UInt8]
    private var decomposed: [UInt8]
    private var disposed = false

    /// PDF apps may print the file.
    public let allowPrinting: Bool

    /// PDF apps may copy its text and images.
    public let allowCopying: Bool

    /// `password` is what the user typed; it must pass `problem` (typed twice the same), else this
    /// throws with the problem.
    public init(_ password: String, allowPrinting: Bool = true, allowCopying: Bool = true) throws {
        if let problem = PDFProtection.problem(password, password) {
            throw ScanError.exportFailed(problem)
        }
        self.prepared = PDFProtection.preparePassword(password)
        self.decomposed = PDFProtection.decomposePassword(password)
        self.allowPrinting = allowPrinting
        self.allowCopying = allowCopying
    }

    deinit {
        PDFEncryption.wipe(&prepared)
        PDFEncryption.wipe(&decomposed)
    }

    /// The file's /P value (`permissions`).
    public var permissionFlags: Int {
        PDFProtection.permissions(allowPrinting: allowPrinting, allowCopying: allowCopying)
    }

    /// The prepared password (`preparePassword`); throws once disposed.
    func password() throws -> [UInt8] {
        if disposed { throw ScanError.exportFailed("The password was already wiped.") }
        return prepared
    }

    /// The password decomposed (`decomposePassword`); throws once disposed.
    func decomposedPassword() throws -> [UInt8] {
        if disposed { throw ScanError.exportFailed("The password was already wiped.") }
        return decomposed
    }

    /// Wipes the prepared password; the protection can't be used after.
    public func dispose() {
        PDFEncryption.wipe(&prepared)
        PDFEncryption.wipe(&decomposed)
        disposed = true
    }

    /// The /P value: -4 (every bit an app checks set: print, change, copy, notes, forms, extract for
    /// accessibility, assemble, print in high quality; bits 1-2 clear), with bits 3 and 12 cleared
    /// when printing is not allowed and bit 5 when copying is not. Bit 10 (extracting for
    /// accessibility) stays set, as PDF 2.0 asks.
    public static func permissions(allowPrinting: Bool, allowCopying: Bool) -> Int {
        var p: Int = -4
        if !allowPrinting { p &= ~((1 << 2) | (1 << 11)) }
        if !allowCopying { p &= ~(1 << 4) }
        return p
    }

    /// The bytes a typed password stands for, as PDF 2.0 prepares it (SASLprep, RFC 4013): spaces
    /// other than U+0020 become U+0020, characters that are "commonly mapped to nothing" (soft
    /// hyphen, zero-width joiners, variation selectors, ...) are dropped, the rest is NFKC
    /// normalized, encoded as UTF-8 and cut to `maxPasswordBytes` bytes. SASLprep's prohibited
    /// characters are refused before this by `problem` (control characters) or are kept as they are.
    public static func preparePassword(_ password: String) -> [UInt8] {
        utf8Cut(mapped(password).precomposedStringWithCompatibilityMapping)
    }

    /// The bytes the Mac's PDFKit makes of a typed password (`PDFDocument.unlock`, and so Preview and
    /// the Mac app): the password with `preparePassword`'s mappings, decomposed (NFKD) rather than
    /// composed, in UTF-8, cut at `maxPasswordBytes` bytes. The same bytes as the prepared
    /// password unless it has a character that decomposes (an accented letter, a Hangul syllable, ...).
    public static func decomposePassword(_ password: String) -> [UInt8] {
        utf8Cut(mapped(password).decomposedStringWithCompatibilityMapping)
    }

    /// SASLprep's mappings: other spaces to U+0020, the characters mapped to nothing dropped.
    private static func mapped(_ password: String) -> String {
        var mapped = String.UnicodeScalarView()
        for scalar in password.unicodeScalars {
            let c = Int(scalar.value)
            if isNonASCIISpace(c) {
                mapped.append(Unicode.Scalar(UInt8(0x20)))
            } else if !mapsToNothing(c) {
                mapped.append(scalar)
            }
        }
        return String(mapped)
    }

    /// `text` in UTF-8, cut at `maxPasswordBytes` bytes.
    private static func utf8Cut(_ text: String) -> [UInt8] {
        var utf8: [UInt8] = Array(text.utf8)
        if utf8.count <= maxPasswordBytes { return utf8 }
        let cut: [UInt8] = Array(utf8[0..<maxPasswordBytes])
        PDFEncryption.wipe(&utf8)
        return cut
    }

    private static func isNonASCIISpace(_ c: Int) -> Bool {
        c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200B) || c == 0x202F || c == 0x205F || c == 0x3000
    }

    private static func mapsToNothing(_ c: Int) -> Bool {
        if c == 0x00AD || c == 0x034F || c == 0x1806 { return true }
        if (c >= 0x180B && c <= 0x180D) || c == 0x200C || c == 0x200D || c == 0x2060 { return true }
        return (c >= 0xFE00 && c <= 0xFE0F) || c == 0xFEFF
    }

    /// A UTF-16 code unit C#'s `char.IsControl` calls a control character (U+0000-U+001F, U+007F-U+009F).
    private static func isControl(_ unit: UInt16) -> Bool {
        unit <= 0x1F || (unit >= 0x7F && unit <= 0x9F)
    }

    /// Why a password typed in the dialog can't be used (nil when it can): nothing typed (or only
    /// characters that stand for nothing), a control character, or the second typing differing from
    /// the first (compared code unit by code unit, as C# does). A weak password is allowed;
    /// `strengthOf` says so.
    public static func problem(_ password: String, _ confirmation: String) -> String? {
        if password.utf16.isEmpty { return "Type a password." }
        for unit in password.utf16 where isControl(unit) {
            return "A password can't contain tabs, line breaks or other control characters."
        }
        var preparedBytes: [UInt8] = preparePassword(password)
        let empty: Bool = preparedBytes.isEmpty
        PDFEncryption.wipe(&preparedBytes)
        if empty { return "Type a password." }
        if !password.utf16.elementsEqual(confirmation.utf16) { return "Passwords don't match" }
        return nil
    }

    private static let commonPasswords: Set<String> = [
        "password", "passw0rd", "qwerty", "qwertyuiop", "azerty", "asdfgh", "asdfghjkl", "letmein",
        "welcome", "admin", "iloveyou", "monkey", "dragon", "sunshine", "princess", "football",
        "baseball", "master", "secret", "abc", "abcdef", "abcdefgh", "abcd", "test", "login",
    ]

    /// What `strengthOf` trims from the end of a password before looking it up among well-known ones.
    private static let trailingDigitsAndSymbols: Set<Character> = Set("0123456789!@#$%^&*()-_=+.?, ")

    /// A rough guess of how hard `password` is to guess, for the dialog's hint: its length in
    /// characters times the bits per character of the kinds of characters it uses (lowercase 26,
    /// uppercase 26, digits 10, ASCII symbols and space 33, anything else 100). Under 8 characters,
    /// under 40 bits, a well-known password (with digits or symbols after it) or one or two different
    /// characters is weak; under 64 bits fair; else strong.
    public static func strengthOf(_ password: String) -> PasswordStrength {
        if password.isEmpty { return PasswordStrength.none }
        var lower = false
        var upper = false
        var digit = false
        var symbol = false
        var other = false
        var distinct = Set<UInt32>()
        var length = 0
        for scalar in password.unicodeScalars {
            length += 1
            let c: UInt32 = scalar.value
            distinct.insert(c)
            if c >= 0x61 && c <= 0x7A {
                lower = true
            } else if c >= 0x41 && c <= 0x5A {
                upper = true
            } else if c >= 0x30 && c <= 0x39 {
                digit = true
            } else if c >= 0x20 && c < 0x7F {
                symbol = true
            } else {
                other = true
            }
        }
        var pool = 0
        if lower { pool += 26 }
        if upper { pool += 26 }
        if digit { pool += 10 }
        if symbol { pool += 33 }
        if other { pool += 100 }
        let bits: Double = Double(length) * log2(Double(max(pool, 2)))
        var core: String = password.lowercased()
        while let last = core.last, trailingDigitsAndSymbols.contains(last) {
            core.removeLast()
        }
        var allDigits = true
        for scalar in core.unicodeScalars where scalar.properties.generalCategory != .decimalNumber {
            allDigits = false
            break
        }
        if length < 8 || bits < 40 || distinct.count <= 2 || commonPasswords.contains(core) || allDigits {
            return PasswordStrength.weak
        }
        return bits < 64 ? PasswordStrength.fair : PasswordStrength.strong
    }

    /// The dialog's short line next to the strength bar ("" when nothing is typed).
    public static func strengthLabel(_ strength: PasswordStrength) -> String {
        switch strength {
        case .weak: return "Weak \u{00B7} use 12+ characters"
        case .fair: return "Fair \u{00B7} longer is safer"
        case .strong: return "Strong"
        case .none: return ""
        }
    }

    /// How many of the strength bar's four segments are filled.
    public static func strengthSegments(_ strength: PasswordStrength) -> Int {
        switch strength {
        case .weak: return 1
        case .fair: return 2
        case .strong: return 4
        case .none: return 0
        }
    }

    /// The full advice about a password's strength, on hover and for screen readers ("" when nothing
    /// is typed).
    public static func strengthHint(_ strength: PasswordStrength) -> String {
        switch strength {
        case .weak:
            return "Weak: easy to guess. Longer is stronger: use 12 or more characters, or a few unrelated words."
        case .fair:
            return "Fair. A few more characters, or another word, would make it much harder to guess."
        case .strong:
            return "Strong."
        case .none:
            return ""
        }
    }
}

/// The standard security handler of PDF 2.0 (ISO 32000-2, 7.6.4) at its current level: V 5, R 6,
/// AES-256. One instance encrypts one file: its random 32-byte file key encrypts every string and
/// stream (AES-256-CBC, PKCS#7 padding, a random 16-byte IV before the data), and the /U, /UE, /O,
/// /OE and /Perms values let a PDF app check the password and recover the key (algorithms 8, 9 and
/// 10, with the hash of algorithm 2.B). The owner password is 32 random bytes nobody knows, so the
/// permissions apply to everyone who opens the file; but when the password has a character that
/// decomposes, it is the password as PDFKit passes it on (`PDFProtection.decomposePassword`), as
/// PDFKit tries no other form: PDFKit then opens the file as its owner, without the permissions.
/// `dispose()` wipes the file key. Twin of C# `PdfEncryption`.
public final class PDFEncryption {
    /// The bytes the random source gives, in this order: file key, user validation and key salts,
    /// owner password, owner validation and key salts, the /Perms filler; then 16 per IV.
    public static let fileKeyLength = 32
    public static let saltLength = 8
    public static let ownerPasswordLength = 32
    public static let permsRandomLength = 4
    public static let ivLength = 16

    private var fileKey: [UInt8]
    private let random: PDFRandomSource
    private var disposed = false

    /// The permissions (/P).
    public let p: Int

    /// /O: 48 bytes, the owner password's hash and its validation and key salts.
    public let o: [UInt8]

    /// /U: 48 bytes, the user password's hash and its validation and key salts.
    public let u: [UInt8]

    /// /OE: the file key encrypted with a key made from the owner password (32 bytes).
    public let oe: [UInt8]

    /// /UE: the file key encrypted with a key made from the user password (32 bytes).
    public let ue: [UInt8]

    /// /Perms: the permissions encrypted with the file key, so a changed /P is noticed (16 bytes).
    public let perms: [UInt8]

    private init(fileKey: [UInt8], random: @escaping PDFRandomSource, permissions: Int,
                 o: [UInt8], u: [UInt8], oe: [UInt8], ue: [UInt8], perms: [UInt8]) {
        self.fileKey = fileKey
        self.random = random
        self.p = permissions
        self.o = o
        self.u = u
        self.oe = oe
        self.ue = ue
        self.perms = perms
    }

    deinit {
        PDFEncryption.wipe(&fileKey)
    }

    /// The system's cryptographic random generator (`SecRandomCopyBytes`).
    public static let systemRandom: PDFRandomSource = { (count: Int) throws -> [UInt8] in
        var bytes = [UInt8](repeating: 0, count: count)
        if count == 0 { return bytes }
        let status: Int32 = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            throw ScanError.exportFailed("No random bytes for the PDF's encryption (error \(status)).")
        }
        return bytes
    }

    /// `count` bytes from `random`, which must give exactly that many.
    static func randomBytes(_ random: PDFRandomSource, _ count: Int) throws -> [UInt8] {
        let bytes: [UInt8] = try random(count)
        if bytes.count != count {
            throw ScanError.exportFailed("The random source gave \(bytes.count) bytes, not \(count).")
        }
        return bytes
    }

    /// The encryption of one file protected by `protection`. Its keys, salts and IVs come from
    /// `random` (nil: `systemRandom`; tests give fixed bytes, in the order of `fileKeyLength`'s
    /// summary). Throws once `protection` is disposed.
    public static func create(_ protection: PDFProtection, random: PDFRandomSource? = nil) throws -> PDFEncryption {
        let source: PDFRandomSource = random ?? systemRandom
        let fileKey: [UInt8] = try randomBytes(source, fileKeyLength)
        let userValidationSalt: [UInt8] = try randomBytes(source, saltLength)
        let userKeySalt: [UInt8] = try randomBytes(source, saltLength)
        var ownerPassword: [UInt8] = try randomBytes(source, ownerPasswordLength)
        defer { wipe(&ownerPassword) }
        let ownerValidationSalt: [UInt8] = try randomBytes(source, saltLength)
        let ownerKeySalt: [UInt8] = try randomBytes(source, saltLength)
        let permsRandom: [UInt8] = try randomBytes(source, permsRandomLength)
        var userPassword: [UInt8] = try protection.password()
        defer { wipe(&userPassword) }
        var decomposed: [UInt8] = try protection.decomposedPassword()
        defer { wipe(&decomposed) }
        let owner: [UInt8] = decomposed == userPassword ? ownerPassword : decomposed
        return try create(userPassword: userPassword, ownerPassword: owner, fileKey: fileKey,
                          userValidationSalt: userValidationSalt, userKeySalt: userKeySalt,
                          ownerValidationSalt: ownerValidationSalt, ownerKeySalt: ownerKeySalt,
                          permissions: protection.permissionFlags, permsRandom: permsRandom, random: source)
    }

    /// The same with every value given (algorithms 8, 9 and 10).
    static func create(userPassword: [UInt8], ownerPassword: [UInt8], fileKey: [UInt8],
                       userValidationSalt: [UInt8], userKeySalt: [UInt8],
                       ownerValidationSalt: [UInt8], ownerKeySalt: [UInt8],
                       permissions: Int, permsRandom: [UInt8],
                       random: @escaping PDFRandomSource) throws -> PDFEncryption {
        if fileKey.count != fileKeyLength { throw ScanError.exportFailed("The file key is 32 bytes.") }
        // Algorithm 8: /U and /UE.
        var u: [UInt8] = try hash(userPassword, salt: userValidationSalt, userKey: [])
        u.append(contentsOf: userValidationSalt)
        u.append(contentsOf: userKeySalt)
        var userKey: [UInt8] = try hash(userPassword, salt: userKeySalt, userKey: [])
        let ue: [UInt8] = try encryptKey(userKey, fileKey)
        // Algorithm 9: /O and /OE, hashed with the whole /U.
        var o: [UInt8] = try hash(ownerPassword, salt: ownerValidationSalt, userKey: u)
        o.append(contentsOf: ownerValidationSalt)
        o.append(contentsOf: ownerKeySalt)
        var ownerKey: [UInt8] = try hash(ownerPassword, salt: ownerKeySalt, userKey: u)
        let oe: [UInt8] = try encryptKey(ownerKey, fileKey)
        wipe(&userKey)
        wipe(&ownerKey)
        // Algorithm 10: /Perms.
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: permissions))
        var block: [UInt8] = [
            UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
            0xFF, 0xFF, 0xFF, 0xFF,
            0x54, // "T": /EncryptMetadata true
            0x61, 0x64, 0x62, // "adb"
        ]
        for i in 0..<4 { block.append(permsRandom[i]) }
        let perms: [UInt8] = try aes(kCCEncrypt, key: fileKey, iv: zeroIV(), options: kCCOptionECBMode, data: block)
        wipe(&block)
        return PDFEncryption(fileKey: fileKey, random: random, permissions: permissions,
                             o: o, u: u, oe: oe, ue: ue, perms: perms)
    }

    /// A 32-byte file key encrypted with AES-256 in CBC mode, a zero IV and no padding (/UE, /OE).
    private static func encryptKey(_ key: [UInt8], _ fileKey: [UInt8]) throws -> [UInt8] {
        try aes(kCCEncrypt, key: key, iv: zeroIV(), options: 0, data: fileKey)
    }

    /// The /Encrypt dictionary: never encrypted itself; the trailer points at it.
    public var dictionary: String {
        var text = "<</Filter /Standard /V 5 /R 6 /Length 256 "
        text += "/CF <</StdCF <</CFM /AESV3 /AuthEvent /DocOpen /Length 32>>>> /StmF /StdCF /StrF /StdCF "
        text += "/O <" + PDFEncryption.hex(o) + "> /U <" + PDFEncryption.hex(u) + "> "
        text += "/OE <" + PDFEncryption.hex(oe) + "> /UE <" + PDFEncryption.hex(ue) + "> "
        text += "/Perms <" + PDFEncryption.hex(perms) + "> /P \(p) /EncryptMetadata true>>"
        return text
    }

    /// A string's or stream's bytes as stored: a random 16-byte IV, then the data encrypted with the
    /// file key in AES-256-CBC with PKCS#7 padding. In V 5 the file key itself is used for every
    /// object. Throws once disposed.
    public func encrypt(_ data: [UInt8]) throws -> [UInt8] {
        if disposed { throw ScanError.exportFailed("The PDF's encryption key was already wiped.") }
        let iv: [UInt8] = try PDFEncryption.randomBytes(random, PDFEncryption.ivLength)
        let encrypted: [UInt8] = try PDFEncryption.aes(kCCEncrypt, key: fileKey, iv: iv,
                                                       options: kCCOptionPKCS7Padding, data: data)
        var stored: [UInt8] = iv
        stored.append(contentsOf: encrypted)
        return stored
    }

    /// Wipes the file key; nothing more can be encrypted.
    public func dispose() {
        PDFEncryption.wipe(&fileKey)
        disposed = true
    }

    // MARK: - Algorithm 2.B and the reader's side

    /// Algorithm 2.B of ISO 32000-2, the hash behind /U, /O, /UE and /OE:
    /// K = SHA-256(password ‖ salt ‖ userKey); then rounds of K1 = (password ‖ K ‖ userKey) × 64,
    /// E = AES-128-CBC(K1) keyed with K's first 16 bytes and its next 16 as the IV, no padding, and
    /// K = SHA-256, SHA-384 or SHA-512 of E as the sum of E's first 16 bytes modulo 3 is 0, 1 or 2;
    /// at least 64 rounds, and on while E's last byte is above the round number minus 32. Returns
    /// K's first 32 bytes. `userKey` is the 48-byte /U for the owner password, else empty.
    public static func hash(_ password: [UInt8], salt: [UInt8], userKey: [UInt8]) throws -> [UInt8] {
        var first: [UInt8] = password
        first.append(contentsOf: salt)
        first.append(contentsOf: userKey)
        var k: [UInt8] = Array(SHA256.hash(data: first))
        wipe(&first)
        var e: [UInt8] = []
        var round = 0
        while round < 64 || Int(e[e.count - 1]) > round - 32 {
            var k1: [UInt8] = []
            k1.reserveCapacity((password.count + k.count + userKey.count) * 64)
            for _ in 0..<64 {
                k1.append(contentsOf: password)
                k1.append(contentsOf: k)
                k1.append(contentsOf: userKey)
            }
            let key: [UInt8] = Array(k[0..<16])
            let iv: [UInt8] = Array(k[16..<32])
            wipe(&e)
            e = try aes(kCCEncrypt, key: key, iv: iv, options: 0, data: k1)
            wipe(&k1)
            var sum = 0
            for i in 0..<16 { sum += Int(e[i]) }
            wipe(&k)
            k = digest(e, kind: sum % 3)
            round += 1
        }
        wipe(&e)
        let result: [UInt8] = Array(k[0..<32])
        wipe(&k)
        return result
    }

    /// SHA-256 of `data` for `kind` 0, SHA-384 for 1, SHA-512 for 2.
    private static func digest(_ data: [UInt8], kind: Int) -> [UInt8] {
        switch kind {
        case 0: return Array(SHA256.hash(data: data))
        case 1: return Array(SHA384.hash(data: data))
        default: return Array(SHA512.hash(data: data))
        }
    }

    /// What a PDF app does with a typed password (algorithm 2.A): the file key when the prepared
    /// `password` is the owner's (checked first) or the user's, else nil.
    public static func fileKeyFor(_ password: [UInt8], o: [UInt8], u: [UInt8], oe: [UInt8],
                                  ue: [UInt8]) throws -> [UInt8]? {
        if o.count < 48 || u.count < 48 || oe.count != 32 || ue.count != 32 { return nil }
        let typed: [UInt8] = Array(password.prefix(PDFProtection.maxPasswordBytes))
        let userBytes: [UInt8] = Array(u[0..<48])
        let ownerHash: [UInt8] = try hash(typed, salt: Array(o[32..<40]), userKey: userBytes)
        if ownerHash == Array(o[0..<32]) {
            return try decryptKey(hash(typed, salt: Array(o[40..<48]), userKey: userBytes), oe)
        }
        let userHash: [UInt8] = try hash(typed, salt: Array(u[32..<40]), userKey: [])
        if userHash == Array(u[0..<32]) {
            return try decryptKey(hash(typed, salt: Array(u[40..<48]), userKey: []), ue)
        }
        return nil
    }

    private static func decryptKey(_ key: [UInt8], _ encrypted: [UInt8]) throws -> [UInt8] {
        var used: [UInt8] = key
        defer { wipe(&used) }
        return try aes(kCCDecrypt, key: used, iv: zeroIV(), options: 0, data: encrypted)
    }

    /// Algorithm 13: /Perms decrypted with the file key holds "adb" and the same /P, so the
    /// permissions were not changed.
    public static func permsMatch(fileKey: [UInt8], perms: [UInt8], p: Int) -> Bool {
        if fileKey.count != fileKeyLength || perms.count != 16 { return false }
        guard let block = try? aes(kCCDecrypt, key: fileKey, iv: zeroIV(), options: kCCOptionECBMode,
                                   data: perms), block.count == 16 else { return false }
        let b0 = UInt32(block[0])
        let b1 = UInt32(block[1]) << 8
        let b2 = UInt32(block[2]) << 16
        let b3 = UInt32(block[3]) << 24
        let stored = Int(Int32(bitPattern: b0 | b1 | b2 | b3))
        return block[9] == 0x61 && block[10] == 0x64 && block[11] == 0x62 && stored == p
    }

    /// A stored string or stream decrypted with the file key (its first 16 bytes are the IV).
    public static func decrypt(fileKey: [UInt8], stored: [UInt8]) throws -> [UInt8] {
        if stored.count < ivLength * 2 || stored.count % 16 != 0 {
            throw ScanError.exportFailed("Not an AES-256 encrypted string or stream.")
        }
        let iv: [UInt8] = Array(stored[0..<ivLength])
        let data: [UInt8] = Array(stored[ivLength..<stored.count])
        return try aes(kCCDecrypt, key: fileKey, iv: iv, options: kCCOptionPKCS7Padding, data: data)
    }

    // MARK: - Helpers

    /// AES with CommonCrypto: `operation` is `kCCEncrypt` or `kCCDecrypt`, the key 16 or 32 bytes,
    /// `options` 0 (CBC, no padding), `kCCOptionPKCS7Padding` or `kCCOptionECBMode` (no padding).
    static func aes(_ operation: Int, key: [UInt8], iv: [UInt8], options: Int, data: [UInt8]) throws -> [UInt8] {
        // An empty input still needs a pointer to hand over; its length stays 0.
        let input: [UInt8] = data.isEmpty ? [0] : data
        let inputCount: Int = data.count
        let keyCount: Int = key.count
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let outputCount: Int = output.count
        var moved: Int = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { (keyBytes: UnsafeRawBufferPointer) -> CCCryptorStatus in
            iv.withUnsafeBytes { (ivBytes: UnsafeRawBufferPointer) -> CCCryptorStatus in
                input.withUnsafeBytes { (inBytes: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    output.withUnsafeMutableBytes { (outBytes: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
                        CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(options),
                                keyBytes.baseAddress, keyCount, ivBytes.baseAddress,
                                inBytes.baseAddress, inputCount,
                                outBytes.baseAddress, outputCount, &moved)
                    }
                }
            }
        }
        if status != CCCryptorStatus(kCCSuccess) {
            wipe(&output)
            throw ScanError.exportFailed("AES failed (CommonCrypto status \(status)).")
        }
        let result: [UInt8] = Array(output[0..<moved])
        wipe(&output)
        return result
    }

    /// Sixteen zero bytes: the IV of /UE and /OE (and the unused one of ECB).
    private static func zeroIV() -> [UInt8] {
        [UInt8](repeating: 0, count: 16)
    }

    /// Bytes as upper-case hex digits (C#'s `Convert.ToHexString`).
    static func hex(_ bytes: [UInt8]) -> String {
        let digits: [Character] = Array("0123456789ABCDEF")
        var text = ""
        text.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// Overwrites `bytes` with zeros (C#'s `CryptographicOperations.ZeroMemory`; a best effort, as
    /// copies Swift made earlier are not reached).
    static func wipe(_ bytes: inout [UInt8]) {
        for i in 0..<bytes.count { bytes[i] = 0 }
    }
}
