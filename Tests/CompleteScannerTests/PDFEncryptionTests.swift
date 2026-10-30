import XCTest
import CommonCrypto
import CoreGraphics
import Foundation
import PDFKit
@testable import CompleteScannerKit

// Mirrors windows/LazyScan.Core.Tests/PdfEncryptionTests.cs: the standard security handler
// V5 R6 (AES-256) checked against known answers (pdf.js's PDF 2.0 cases, Apache-2.0), the password
// rules and texts, the values and the whole file pinned in C# for the same password and random
// bytes, then whole files read back. C# reads them with PdfPig; here PDFKit opens them, locked, and
// unlocks them with the user's password and with the owner password (`PDFDocument.unlock`), on the
// Mac and in the iOS Simulator.

final class PDFEncryptionTests: XCTestCase {
    // Known answers for algorithm 2.B and the file key: the PDF 2.0 (revision 6) cases of pdf.js,
    // test/unit/crypto_spec.js ("PDF20Algorithm" and "AES256 Revision 6"), Apache-2.0.
    private static let isoU: [UInt8] = hex("5EE6CD4BA663FA4CDB801155391121A4962E67B0A09CBBE9A6DFA3FD93EB5FB8" + "53F59265C6F722C6" + "BF0B105EEDD814AF")
    private static let isoO: [UInt8] = hex("58E83E36F51AF5D1897BDD48C73125D91F4A73A77F9EB04D2DA3572F275AD98D" + "8EE8A9D0CAD605B9" + "1DD0B92E0B4C8795")
    private static let isoUE: [UInt8] = hex("79D002B5E6599C3CFD8FD41C54B4C4B1AD80DD6B2E145EBA87335F1814DFFE24")
    private static let isoOE: [UInt8] = hex("D149E04D679BC9B5BE44DF143E5A38D205F0B280EE7C44FEFDF43E6CD0870AFB")
    private static let isoPerms: [UInt8] = hex("6CAD0FA0EB4D86574D3ECBB5E058C937")
    private static let isoP = -1084
    private static let isoFileKey: [UInt8] = hex("2ADAD527495B484F4326F88512BD3D226B4F1D383BB5D576712241D257AE16EF")

    // The same suite's "AES256 Revision 6 with SASLprep" dictionary: made with the password "SaSLprep".
    private static let saslU: [UInt8] = latin1Bytes(
        "%98%1E%80%12%14Y%93D%0By%2F%07q%5E%CC%7B%D1%CDg%2C%5B2%DD%B7%C0%7D%C7%D5%1F5Q%23%BD%CA1%FDm%7B%B7%D1%60%29v%91%D23%E1%B4")
    private static let saslO: [UInt8] = latin1Bytes(
        "%21%14%DF%F5%89%2A%5F%97%B6%B7%EB%F8P%02%7DY%FD%95%82%CA%BD%1C%A6T%5E%8Bq%01%FC%9D%D2%00%84z%F4%89%E8%3EX%DFq%CF%CE%F2F%A6%B2%95")
    private static let saslOE: [UInt8] = latin1Bytes(
        "A%F1%BF%91%AA%8B%F03%D8m%CF%0B%14%19%D6%BF%8B%2AO%FAln%AAb%85%F2SB%7C%CF%FBX")
    private static let saslUE: [UInt8] = latin1Bytes(
        "w%20v%EF%AD%EC%02%AD%C6%1B%06%DEP%DE%BE8%DD%A5%DB%C77%8E%035L%1D%FD%DD%13%83%AC%9B")
    private static let saslPerms: [UInt8] = latin1Bytes("%0E%FE%02%22%FB5f%A68t%0Ca%11%17Jf")

    /// Bytes from hex digits.
    static func hex(_ text: String) -> [UInt8] {
        let digits: [UInt8] = Array(text.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < digits.count {
            let high: UInt8 = nibble(digits[i])
            let low: UInt8 = nibble(digits[i + 1])
            bytes.append(high << 4 | low)
            i += 2
        }
        return bytes
    }

    private static func nibble(_ digit: UInt8) -> UInt8 {
        if digit >= 0x30 && digit <= 0x39 { return digit - 0x30 }
        if digit >= 0x41 && digit <= 0x46 { return digit - 0x41 + 10 }
        return digit - 0x61 + 10
    }

    /// The JavaScript unescape() of a %XX-escaped Latin-1 string, as bytes.
    private static func latin1Bytes(_ escaped: String) -> [UInt8] {
        let source: [UInt8] = Array(escaped.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < source.count {
            if source[i] == 0x25 && i + 2 < source.count {
                bytes.append(nibble(source[i + 1]) << 4 | nibble(source[i + 2]))
                i += 3
            } else {
                bytes.append(source[i])
                i += 1
            }
        }
        return bytes
    }

    private static func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }

    private static func bytes(_ range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        for value in range { result.append(UInt8(truncatingIfNeeded: value)) }
        return result
    }

    /// A random source that gives 0, 1, 2, … 255, 0, … across calls, so files come out the same.
    static func counting() -> PDFRandomSource {
        let state = CountingState()
        return { (count: Int) throws -> [UInt8] in
            var result: [UInt8] = []
            for _ in 0..<count {
                result.append(state.next)
                state.next = state.next &+ 1
            }
            return result
        }
    }

    private final class CountingState {
        var next: UInt8 = 0
    }

    /// `data` decrypted with AES-256-CBC, a zero IV and no padding (/UE, /OE).
    private static func unwrap(_ key: [UInt8], _ wrapped: [UInt8]) throws -> [UInt8] {
        try PDFEncryption.aes(kCCDecrypt, key: key, iv: [UInt8](repeating: 0, count: 16), options: 0, data: wrapped)
    }

    // MARK: - Algorithm 2.B and the file key (known answers)

    func test_hash_userPassword_knownAnswer() throws {
        XCTAssertEqual(try PDFEncryption.hash(Self.utf8("user"), salt: Array(Self.isoU[32..<40]), userKey: []),
                       Array(Self.isoU[0..<32]))
    }

    func test_hash_ownerPassword_isHashedWithTheWholeU_knownAnswer() throws {
        XCTAssertEqual(try PDFEncryption.hash(Self.utf8("owner"), salt: Array(Self.isoO[32..<40]), userKey: Self.isoU),
                       Array(Self.isoO[0..<32]))
    }

    func test_fileKey_fromUEAndOE_knownAnswer() throws {
        let userKey = try PDFEncryption.hash(Self.utf8("user"), salt: Array(Self.isoU[40..<48]), userKey: [])
        XCTAssertEqual(try Self.unwrap(userKey, Self.isoUE), Self.isoFileKey)
        let ownerKey = try PDFEncryption.hash(Self.utf8("owner"), salt: Array(Self.isoO[40..<48]), userKey: Self.isoU)
        XCTAssertEqual(try Self.unwrap(ownerKey, Self.isoOE), Self.isoFileKey)
    }

    func test_fileKeyFor_opensTheIsoDictionary_withEitherPassword_andNoOther() throws {
        XCTAssertEqual(try PDFEncryption.fileKeyFor(Self.utf8("user"), o: Self.isoO, u: Self.isoU, oe: Self.isoOE, ue: Self.isoUE),
                       Self.isoFileKey)
        XCTAssertEqual(try PDFEncryption.fileKeyFor(Self.utf8("owner"), o: Self.isoO, u: Self.isoU, oe: Self.isoOE, ue: Self.isoUE),
                       Self.isoFileKey)
        XCTAssertNil(try PDFEncryption.fileKeyFor(Self.utf8("wrong"), o: Self.isoO, u: Self.isoU, oe: Self.isoOE, ue: Self.isoUE))
        XCTAssertNil(try PDFEncryption.fileKeyFor([], o: Self.isoO, u: Self.isoU, oe: Self.isoOE, ue: Self.isoUE))
        // The fixture's /P (-1084) was changed after its /Perms was made (for -4): what /Perms is there to show.
        XCTAssertTrue(PDFEncryption.permsMatch(fileKey: Self.isoFileKey, perms: Self.isoPerms, p: -4))
        XCTAssertFalse(PDFEncryption.permsMatch(fileKey: Self.isoFileKey, perms: Self.isoPerms, p: Self.isoP))
    }

    func test_preparedPassword_opensTheSaslPrepDictionary() throws {
        XCTAssertEqual(Self.saslU.count, 48)
        XCTAssertEqual(Self.saslO.count, 48)
        // "S" "ª" "SL" soft hyphen "prep": ª is "a" in compatibility form, the soft hyphen is nothing.
        let prepared = PDFProtection.preparePassword("S\u{AA}SL\u{AD}prep")
        XCTAssertEqual(prepared, Self.utf8("SaSLprep"))
        let key = try XCTUnwrap(try PDFEncryption.fileKeyFor(prepared, o: Self.saslO, u: Self.saslU, oe: Self.saslOE,
                                                             ue: Self.saslUE))
        XCTAssertTrue(PDFEncryption.permsMatch(fileKey: key, perms: Self.saslPerms, p: -4))
        XCTAssertNil(try PDFEncryption.fileKeyFor(Self.utf8("wrong"), o: Self.saslO, u: Self.saslU, oe: Self.saslOE,
                                                  ue: Self.saslUE))
    }

    // MARK: - Passwords

    func test_preparePassword_mapsSpaces_dropsInvisibles_normalizes_andCutsAt127Bytes() {
        XCTAssertEqual(PDFProtection.preparePassword("a\u{A0}b\u{3000}c"), Self.utf8("a b c"))
        XCTAssertEqual(PDFProtection.preparePassword("x\u{AD}\u{200D}y\u{FE0F}"), Self.utf8("xy"))
        XCTAssertEqual(PDFProtection.preparePassword("\u{FB01}le"), Self.utf8("file")) // the "fi" ligature
        XCTAssertEqual(PDFProtection.preparePassword("C\u{327}ag\u{306}r\u{131}"), Self.utf8("Çağrı")) // composed
        XCTAssertEqual(PDFProtection.preparePassword("Şifre 2026"), Self.utf8("Şifre 2026"))
        XCTAssertEqual(PDFProtection.preparePassword(String(repeating: "a", count: 200)).count, 127)
        // Readers cut the bytes, not the characters, so a cut may fall inside one: "ğ" is two bytes.
        let cut = PDFProtection.preparePassword(String(repeating: "ğ", count: 100))
        XCTAssertEqual(cut.count, 127)
        XCTAssertEqual(cut, Array(Self.utf8(String(repeating: "ğ", count: 64))[0..<127]))
    }

    func test_decomposePassword_isThePreparedPassword_decomposed_asPDFKitPassesItOn() {
        // "Ş" is "S" and a combining cedilla (U+0327) once decomposed.
        XCTAssertEqual(PDFProtection.decomposePassword("Şifre 2026"), Self.hex("53CCA7696672652032303236"))
        XCTAssertEqual(PDFProtection.decomposePassword("\u{C7}a\u{11F}r\u{131}"), Self.utf8("C\u{327}ag\u{306}r\u{131}"))
        XCTAssertEqual(PDFProtection.decomposePassword("\u{FB01}le"), Self.utf8("file")) // the "fi" ligature
        XCTAssertEqual(PDFProtection.decomposePassword("a\u{A0}b\u{3000}c"), Self.utf8("a b c"))
        XCTAssertEqual(PDFProtection.decomposePassword("x\u{AD}\u{200D}y\u{FE0F}"), Self.utf8("xy"))
        // A Hangul syllable becomes its letters; ideographs and ASCII stay as they are.
        XCTAssertEqual(PDFProtection.decomposePassword("\u{D55C}\u{AE00}"), Self.hex("E18492E185A1E186ABE18480E185B3E186AF"))
        XCTAssertEqual(PDFProtection.decomposePassword("\u{5BC6}\u{7801}"), PDFProtection.preparePassword("\u{5BC6}\u{7801}"))
        XCTAssertEqual(PDFProtection.decomposePassword("pw"), Self.utf8("pw"))
        XCTAssertEqual(PDFProtection.decomposePassword(String(repeating: "ğ", count: 100)).count, 127)
    }

    func test_problem_needsAPassword_typedTwiceTheSame_withoutControlCharacters() {
        XCTAssertNil(PDFProtection.problem("correct horse", "correct horse"))
        XCTAssertNil(PDFProtection.problem("a", "a")) // weak but allowed
        XCTAssertEqual(PDFProtection.problem("", ""), "Type a password.")
        // Only characters that stand for nothing: the file would open without a password.
        XCTAssertEqual(PDFProtection.problem("\u{AD}\u{200D}", "\u{AD}\u{200D}"), "Type a password.")
        XCTAssertEqual(PDFProtection.problem("Şifre", "Sifre"), "Passwords don't match")
        XCTAssertEqual(PDFProtection.problem("a\tb", "a\tb"),
                       "A password can't contain tabs, line breaks or other control characters.")
        XCTAssertThrowsError(try PDFProtection(""))
        XCTAssertThrowsError(try PDFProtection("line\nbreak"))
    }

    func test_strengthOf_guessesHowHardAPasswordIsToGuess() {
        let cases: [(String, PasswordStrength)] = [
            ("", PasswordStrength.none),
            ("abc", .weak),
            ("Password123!", .weak),   // a well-known word with digits after it
            ("12345678901234", .weak), // digits only
            ("aaaaaaaaaaaaaaaaaaaa", .weak),
            ("kediler", .weak),        // 7 characters
            ("kedilerim", .fair),      // 9 lowercase letters: 42 bits
            ("tavukpilavci", .fair),   // 12: 56 bits
            ("tavuk-pilav9", .strong), // 12 of three kinds: 73 bits
            ("Uzun bir cümle, üç kelime!", .strong),
            ("correct horse battery staple", .strong),
        ]
        for (password, expected) in cases {
            XCTAssertEqual(PDFProtection.strengthOf(password), expected, password)
            XCTAssertEqual(PDFProtection.strengthHint(expected).isEmpty, expected == PasswordStrength.none, password)
        }
    }

    func test_strengthLabel_isShort_andTheBarFillsWithTheStrength() {
        XCTAssertEqual(PDFProtection.strengthLabel(PasswordStrength.none), "")
        XCTAssertEqual(PDFProtection.strengthLabel(.weak), "Weak \u{00B7} use 12+ characters")
        XCTAssertEqual(PDFProtection.strengthLabel(.strong), "Strong")
        for strength in PasswordStrength.allCases {
            // A few words on screen; the full advice stays the tooltip.
            var words = 0
            for word in PDFProtection.strengthLabel(strength).split(separator: " ") {
                if word.contains(where: { $0.isLetter || $0.isNumber }) { words += 1 }
            }
            XCTAssertLessThanOrEqual(words, 5)
        }
        var segments: [Int] = []
        for strength in [PasswordStrength.none, .weak, .fair, .strong] {
            segments.append(PDFProtection.strengthSegments(strength))
        }
        XCTAssertEqual(segments, [0, 1, 2, 4])
    }

    func test_passwordAndArchival_nameEachOtherInTheirShortReasons() {
        XCTAssertEqual(PDFProtection.notWithArchivalReason, "Not with PDF/A")
        XCTAssertEqual(PDFA.notWithPasswordReason, "Not with a password")
        // The error PDFWriter throws keeps its full sentence.
        XCTAssertEqual(PDFA.cannotProtectNote, "PDF/A can't be password-protected.")
    }

    func test_permissions_allowEverything_orClearThePrintAndCopyBits() throws {
        XCTAssertEqual(PDFProtection.permissions(allowPrinting: true, allowCopying: true), -4)
        XCTAssertEqual(PDFProtection.permissions(allowPrinting: false, allowCopying: true), -4 & ~4 & ~2048)
        XCTAssertEqual(PDFProtection.permissions(allowPrinting: true, allowCopying: false), -4 & ~16)
        XCTAssertEqual(PDFProtection.permissions(allowPrinting: false, allowCopying: false), -2072)
        let protection = try PDFProtection("pw", allowPrinting: false)
        XCTAssertEqual(protection.permissionFlags, -2056)
    }

    func test_protection_wipesItsPasswordWhenDisposed() throws {
        let protection = try PDFProtection("gizli")
        XCTAssertEqual(try protection.password(), Self.utf8("gizli"))
        protection.dispose()
        XCTAssertThrowsError(try protection.password())
        XCTAssertThrowsError(try PDFWriter.make([Self.page()], options: Self.protected(protection)))
    }

    // MARK: - The security handler's values

    func test_create_givenItsRandomBytes_makesTheSameValues_thatOpenWithThePassword() throws {
        let protection = try PDFProtection("Şifre 2026")
        let encryption = try PDFEncryption.create(protection, random: Self.counting())
        // The random bytes are taken in order: file key 0-31, user salts 32-47, owner password 48-79,
        // owner salts 80-95, the /Perms filler 96-99.
        let fileKey = Self.bytes(0..<32)
        XCTAssertEqual(Array(encryption.u[32..<48]), Self.bytes(32..<48))
        XCTAssertEqual(Array(encryption.o[32..<48]), Self.bytes(80..<96))
        XCTAssertEqual(encryption.u.count, 48)
        XCTAssertEqual(encryption.o.count, 48)
        XCTAssertEqual(encryption.ue.count, 32)
        XCTAssertEqual(encryption.oe.count, 32)
        XCTAssertEqual(encryption.perms.count, 16)
        XCTAssertEqual(encryption.p, -4)
        XCTAssertEqual(try PDFEncryption.fileKeyFor(PDFProtection.preparePassword("Şifre 2026"), o: encryption.o, u: encryption.u,
                                                    oe: encryption.oe, ue: encryption.ue), fileKey)
        XCTAssertNil(try PDFEncryption.fileKeyFor(PDFProtection.preparePassword("Sifre 2026"), o: encryption.o, u: encryption.u,
                                                  oe: encryption.oe, ue: encryption.ue))
        // "Ş" decomposes, so the owner password is the password as PDFKit passes it on; the random
        // bytes 48-79 are still taken, and open nothing.
        let decomposed = PDFProtection.decomposePassword("Şifre 2026")
        XCTAssertEqual(try PDFEncryption.hash(decomposed, salt: Array(encryption.o[32..<40]), userKey: encryption.u),
                       Array(encryption.o[0..<32]))
        XCTAssertEqual(try PDFEncryption.fileKeyFor(decomposed, o: encryption.o, u: encryption.u,
                                                    oe: encryption.oe, ue: encryption.ue), fileKey)
        XCTAssertNil(try PDFEncryption.fileKeyFor(Self.bytes(48..<80), o: encryption.o, u: encryption.u,
                                                  oe: encryption.oe, ue: encryption.ue))
        XCTAssertTrue(PDFEncryption.permsMatch(fileKey: fileKey, perms: encryption.perms, p: -4))
        let block = try PDFEncryption.aes(kCCDecrypt, key: fileKey, iv: [UInt8](repeating: 0, count: 16),
                                          options: kCCOptionECBMode, data: encryption.perms)
        XCTAssertEqual(PDFEncryption.hex(block), "FCFFFFFFFFFFFFFF5461646260616263")
        // Pinned in C#: the same password and bytes give the same values.
        XCTAssertEqual(PDFEncryption.hex(encryption.u), Golden.u)
        XCTAssertEqual(PDFEncryption.hex(encryption.o), Golden.o)
        XCTAssertEqual(PDFEncryption.hex(encryption.ue), Golden.ue)
        XCTAssertEqual(PDFEncryption.hex(encryption.oe), Golden.oe)
        XCTAssertEqual(PDFEncryption.hex(encryption.perms), Golden.perms)
    }

    /// The values for "Şifre 2026" and the counting bytes (C#'s `Golden`).
    private enum Golden {
        static let u = "69E56736D0DC99ADAB81C8C974CB117CD64C8EACD3B03BA79DAA6F37ACA51290202122232425262728292A2B2C2D2E2F"
        static let o = "5FBC1E5693C9182C7FF0F1F08FCC86C0151769BFD5E52B6BB85C82CA6947FE31505152535455565758595A5B5C5D5E5F"
        static let ue = "5939E7CB89B321D9B11D24CF5015E35106ED748026E84F76FE7B2542DDEA6E0D"
        static let oe = "C111D7C0AD5019A4F5F79A04440B045F021A190568483E674680507BF74F1A2C"
        static let perms = "A23A07C7EAEAB688EBF15FA2C4DBCB0E"
    }

    func test_create_keepsTheRandomOwnerPassword_whenThePasswordDoesNotDecompose() throws {
        let protection = try PDFProtection("Gizli 2026")
        let encryption = try PDFEncryption.create(protection, random: Self.counting())
        let fileKey = Self.bytes(0..<32)
        // The owner password is the random bytes 48-79, known to nobody.
        let owner = Self.bytes(48..<80)
        XCTAssertEqual(try PDFEncryption.hash(owner, salt: Array(encryption.o[32..<40]), userKey: encryption.u),
                       Array(encryption.o[0..<32]))
        XCTAssertEqual(try PDFEncryption.fileKeyFor(owner, o: encryption.o, u: encryption.u,
                                                    oe: encryption.oe, ue: encryption.ue), fileKey)
        XCTAssertEqual(try PDFEncryption.fileKeyFor(Self.utf8("Gizli 2026"), o: encryption.o, u: encryption.u,
                                                    oe: encryption.oe, ue: encryption.ue), fileKey)
    }

    func test_encrypt_putsARandomIvFirst_padsToTheBlock_andDecryptsBack() throws {
        let protection = try PDFProtection("pw")
        let encryption = try PDFEncryption.create(protection, random: Self.counting())
        let key = Self.bytes(0..<32)
        for length in [0, 1, 15, 16, 17, 1000] {
            var data: [UInt8] = []
            for i in 0..<length { data.append(UInt8(truncatingIfNeeded: i * 7)) }
            let stored = try encryption.encrypt(data)
            XCTAssertEqual(stored.count, 16 + (length / 16 + 1) * 16, "\(length)")
            XCTAssertEqual(try PDFEncryption.decrypt(fileKey: key, stored: stored), data, "\(length)")
        }
        // Each string or stream gets the next 16 random bytes as its IV.
        let first = try encryption.encrypt(Self.utf8("abc"))
        let second = try encryption.encrypt(Self.utf8("abc"))
        XCTAssertNotEqual(Array(first[0..<16]), Array(second[0..<16]))
    }

    func test_dictionary_isTheStandardHandlerV5R6() throws {
        let protection = try PDFProtection("pw", allowCopying: false)
        let encryption = try PDFEncryption.create(protection, random: Self.counting())
        var expected = "<</Filter /Standard /V 5 /R 6 /Length 256 "
        expected += "/CF <</StdCF <</CFM /AESV3 /AuthEvent /DocOpen /Length 32>>>> /StmF /StdCF /StrF /StdCF "
        expected += "/O <\(PDFEncryption.hex(encryption.o))> /U <\(PDFEncryption.hex(encryption.u))> "
        expected += "/OE <\(PDFEncryption.hex(encryption.oe))> /UE <\(PDFEncryption.hex(encryption.ue))> "
        expected += "/Perms <\(PDFEncryption.hex(encryption.perms))> /P -20 /EncryptMetadata true>>"
        XCTAssertEqual(encryption.dictionary, expected)
    }

    // MARK: - Protected files

    private static let id: [UInt8] = bytes(0xB0..<0xC0)
    private static let idHex = "B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF"

    private static func protected(_ protection: PDFProtection) -> PDFWriteOptions {
        var options = PDFWriteOptions(documentId: id, protection: protection)
        options.random = counting()
        return options
    }

    /// A US Letter page at 300 dpi with C#'s TinyJpeg.
    private static func page(_ lines: [OCRLine]? = nil) -> PDFPageInput {
        PDFPageInput(jpegData: PDFWriterTests.tinyJPEGData, pixelWidth: 2550, pixelHeight: 3300, dpi: 300, ocrLines: lines)
    }

    private static let line = OCRLine(text: "Gizli belge — Çağrı Işık",
                                      boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.04), confidence: 0.9)

    private static func has(_ pdf: Data, _ needle: String) -> Bool { PDFWriterTests.has(pdf, needle) }

    /// The value of `/key <hex>` in the file.
    private static func value(_ pdf: Data, _ key: String) throws -> [UInt8] {
        let marker = "/\(key) <"
        let start = try XCTUnwrap(PDFWriterTests.offset(pdf, marker)) + marker.utf8.count
        let end = try XCTUnwrap(PDFWriterTests.offset(pdf, ">", from: start))
        return hex(PDFWriterTests.text(pdf, at: start, count: end - start))
    }

    /// The stored data of stream object `number`.
    private static func stream(_ pdf: Data, _ number: Int) throws -> [UInt8] {
        let head = "\n\(number) 0 obj\n<<"
        let start = try XCTUnwrap(PDFWriterTests.offset(pdf, head), "stream \(number)")
        let lengthMarker = "/Length "
        let lengthStart = try XCTUnwrap(PDFWriterTests.offset(pdf, lengthMarker, from: start)) + lengthMarker.utf8.count
        let lengthEnd = try XCTUnwrap(PDFWriterTests.offset(pdf, ">>\nstream\n", from: lengthStart))
        let length = try XCTUnwrap(Int(PDFWriterTests.text(pdf, at: lengthStart, count: lengthEnd - lengthStart)))
        let data = lengthEnd + ">>\nstream\n".utf8.count
        return [UInt8](pdf.subdata(in: (pdf.startIndex + data)..<(pdf.startIndex + data + length)))
    }

    func test_protected_headerCatalogNumberingAndTrailer() throws {
        let protection = try PDFProtection("Şifre 2026")
        let pdf = try PDFWriter.make([Self.page([Self.line]), Self.page()], options: Self.protected(protection))
        XCTAssertEqual(PDFWriterTests.text(pdf, at: 0, count: 10), "%PDF-1.7\n%")
        XCTAssertEqual(PDFWriterTests.text(pdf, at: pdf.count - 6, count: 6), "%%EOF\n")
        // 1 Catalog, 2 Pages, 3-8 the font, 9 Encrypt, then three objects a page.
        XCTAssertTrue(Self.has(pdf, "1 0 obj\n<</Type /Catalog /Pages 2 0 R /Extensions <</ADBE <</BaseVersion /1.7 /ExtensionLevel 8>>>>>>\nendobj\n"))
        XCTAssertTrue(Self.has(pdf, "2 0 obj\n<</Type /Pages /Kids [10 0 R 13 0 R] /Count 2>>"))
        XCTAssertTrue(Self.has(pdf, "9 0 obj\n<</Filter /Standard /V 5 /R 6 /Length 256 /CF <</StdCF <</CFM /AESV3"))
        XCTAssertTrue(Self.has(pdf, "trailer\n<</Size 16 /Root 1 0 R /Encrypt 9 0 R /ID [<\(Self.idHex)> <\(Self.idHex)>]>>"))
        // The font's strings are encrypted: no "(Adobe)" in the open, a 64-digit hex string each.
        XCTAssertFalse(Self.has(pdf, "(Adobe)"))
        let registry = try Self.value(pdf, "Registry")
        let ordering = try Self.value(pdf, "Ordering")
        XCTAssertEqual(registry.count, 32)
        XCTAssertEqual(ordering.count, 32)
        // Nothing of the page or its text is in the open.
        XCTAssertFalse(Self.has(pdf, "BT\n3 Tr"))
        XCTAssertFalse(Self.has(pdf, "beginbfrange"))
        XCTAssertNil(pdf.range(of: PDFWriterTests.tinyJPEGData.prefix(64)))
        PDFWriterTests.assertXrefPointsAtEveryObject(pdf, objects: 15)
    }

    func test_protected_streamsAndStrings_decryptWithTheKeyThePasswordOpens() throws {
        let protection = try PDFProtection("Şifre 2026")
        let pdf = try PDFWriter.make([Self.page([Self.line])], options: Self.protected(protection))
        let fileKey = try XCTUnwrap(try PDFEncryption.fileKeyFor(PDFProtection.preparePassword("Şifre 2026"),
                                                                 o: Self.value(pdf, "O"), u: Self.value(pdf, "U"),
                                                                 oe: Self.value(pdf, "OE"), ue: Self.value(pdf, "UE")))
        XCTAssertTrue(PDFEncryption.permsMatch(fileKey: fileKey, perms: try Self.value(pdf, "Perms"), p: -4))
        // 9 Encrypt, 10 Page, 11 Image, 12 Contents.
        XCTAssertEqual(try PDFEncryption.decrypt(fileKey: fileKey, stored: Self.stream(pdf, 11)), PDFWriterTests.tinyJPEG)
        let contents = try PDFEncryption.decrypt(fileKey: fileKey, stored: Self.stream(pdf, 12))
        XCTAssertTrue(String(decoding: contents, as: UTF8.self).hasPrefix("q\n612 0 0 792 0 0 cm\n/Im0 Do\nQ\nBT\n3 Tr\n"))
        XCTAssertEqual(try PDFEncryption.decrypt(fileKey: fileKey, stored: Self.stream(pdf, 6)), GlyphlessFont.program)
        // The font program keeps its own length beside the encrypted stream's.
        let program = GlyphlessFont.program.count
        XCTAssertTrue(Self.has(pdf, "6 0 obj\n<</Length1 \(program) /Length \(16 + (program / 16 + 1) * 16)>>"))
        let registry = try PDFEncryption.decrypt(fileKey: fileKey, stored: Self.value(pdf, "Registry"))
        let ordering = try PDFEncryption.decrypt(fileKey: fileKey, stored: Self.value(pdf, "Ordering"))
        XCTAssertEqual(String(decoding: registry, as: UTF8.self), "Adobe")
        XCTAssertEqual(String(decoding: ordering, as: UTF8.self), "Identity")
    }

    func test_protected_opensInPDFKit_withTheUserPassword_orTheOwnerPassword_only() throws {
        let protection = try PDFProtection("Şifre 2026")
        var options = PDFWriteOptions(protection: protection)
        options.random = Self.counting()
        let pdf = try PDFWriter.make([Self.page([Self.line]), Self.page()], options: options)
        // PDFKit passes the password on decomposed, which is this file's owner password ("Ş" decomposes).
        let user = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertTrue(user.isEncrypted)
        XCTAssertTrue(user.isLocked)
        XCTAssertFalse(user.unlock(withPassword: "Sifre 2026"))
        XCTAssertFalse(user.unlock(withPassword: ""))
        XCTAssertTrue(user.isLocked)
        XCTAssertTrue(user.unlock(withPassword: "Şifre 2026"))
        XCTAssertFalse(user.isLocked)
        XCTAssertEqual(user.pageCount, 2)
        let text = user.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Çağrı"), "PDFKit read: \(text)")
        let width = try XCTUnwrap(user.page(at: 1)).bounds(for: .mediaBox).width
        XCTAssertEqual(Double(width), 612, accuracy: 0.01)
        // A password that does not decompose opens the file as its user, so the permissions apply; the
        // counting bytes make the owner password the bytes 48-79: "0123456789:;<=>?@ABCDEFGHIJKLMNO".
        let ascii = try PDFProtection("Gizli 2026", allowPrinting: false)
        var asciiOptions = PDFWriteOptions(protection: ascii)
        asciiOptions.random = Self.counting()
        let asciiPDF = try PDFWriter.make([Self.page()], options: asciiOptions)
        let reader = try XCTUnwrap(PDFDocument(data: asciiPDF))
        XCTAssertTrue(reader.isLocked)
        XCTAssertTrue(reader.unlock(withPassword: "Gizli 2026"))
        XCTAssertFalse(reader.allowsPrinting)
        let owner = try XCTUnwrap(PDFDocument(data: asciiPDF))
        XCTAssertTrue(owner.isLocked)
        XCTAssertTrue(owner.unlock(withPassword: String(decoding: Self.bytes(48..<80), as: UTF8.self)))
        XCTAssertFalse(owner.isLocked)
        XCTAssertTrue(owner.allowsPrinting)
        XCTAssertEqual(owner.pageCount, 1)
    }

    func test_protected_aPasswordThatDecomposes_opensInPDFKit_asItsOwner() throws {
        let typed = "\u{C7}a\u{11F}r\u{131} 2026" // "Çağrı 2026", composed, as keyboards type it
        let protection = try PDFProtection(typed, allowPrinting: false, allowCopying: false)
        let pdf = try PDFWriter.make([Self.page()], options: Self.protected(protection))
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertTrue(document.isLocked)
        XCTAssertFalse(document.unlock(withPassword: "Cagri 2026"))
        XCTAssertTrue(document.unlock(withPassword: typed))
        XCTAssertEqual(document.pageCount, 1)
        #if os(macOS)
        // The Mac's PDFKit tries the decomposed form only, the owner password: the permissions don't
        // apply there.
        XCTAssertTrue(document.allowsPrinting)
        #endif
        // A reader that prepares the password as PDF 2.0 asks (composed) opens the file as its user.
        let prepared = PDFProtection.preparePassword(typed)
        let o = try Self.value(pdf, "O")
        let u = try Self.value(pdf, "U")
        XCTAssertNotEqual(try PDFEncryption.hash(prepared, salt: Array(o[32..<40]), userKey: u), Array(o[0..<32]))
        XCTAssertEqual(try PDFEncryption.hash(prepared, salt: Array(u[32..<40]), userKey: []), Array(u[0..<32]))
        XCTAssertNotNil(try PDFEncryption.fileKeyFor(prepared, o: o, u: u, oe: Self.value(pdf, "OE"), ue: Self.value(pdf, "UE")))
        // So does CoreGraphics, given those bytes.
        let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
        let reference = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertTrue(reference.isEncrypted)
        var bytes: [CChar] = []
        for byte in prepared { bytes.append(CChar(bitPattern: byte)) }
        bytes.append(0)
        let unlocked: Bool = bytes.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<CChar>) -> Bool in
            reference.unlockWithPassword(buffer.baseAddress!)
        }
        XCTAssertTrue(unlocked)
        XCTAssertFalse(reference.allowsPrinting)
    }

    func test_protected_noPrintingOrCopying_isWrittenInP() throws {
        let protection = try PDFProtection("pw", allowPrinting: false, allowCopying: false)
        let pdf = try PDFWriter.make([Self.page()], options: Self.protected(protection))
        XCTAssertTrue(Self.has(pdf, "/P -2072 /EncryptMetadata true>>"))
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertTrue(document.unlock(withPassword: "pw"))
        XCTAssertEqual(document.pageCount, 1)
        // PDFKit honors the permissions for the user's password.
        XCTAssertFalse(document.allowsPrinting)
        XCTAssertFalse(document.allowsCopying)
    }

    func test_protected_eachFileGetsItsOwnKey() throws {
        let protection = try PDFProtection("pw")
        let options = PDFWriteOptions(protection: protection)
        let first = try PDFWriter.make([Self.page()], options: options)
        let second = try PDFWriter.make([Self.page()], options: options)
        XCTAssertNotEqual(try Self.value(first, "U"), try Self.value(second, "U"))
        let firstId = try Self.trailerId(first)
        XCTAssertNotEqual(firstId, try Self.trailerId(second))
        XCTAssertEqual(firstId.count, 32)
        XCTAssertTrue(Self.has(first, "/ID [<\(firstId)> <\(firstId)>]"))
    }

    private static func trailerId(_ pdf: Data) throws -> String {
        let marker = "/ID [<"
        let start = try XCTUnwrap(PDFWriterTests.offset(pdf, marker)) + marker.utf8.count
        let end = try XCTUnwrap(PDFWriterTests.offset(pdf, ">", from: start))
        return PDFWriterTests.text(pdf, at: start, count: end - start)
    }

    func test_protected_andArchival_areRefused() throws {
        let protection = try PDFProtection("pw")
        let both = PDFWriteOptions(conformance: .pdfA2b, protection: protection)
        XCTAssertThrowsError(try PDFWriter.make([Self.page()], options: both)) { error in
            XCTAssertEqual(error.localizedDescription, ScanError.exportFailed(PDFA.cannotProtectNote).localizedDescription)
        }
    }

    func test_writeOptions_followThePasswordSetting() throws {
        let protection = try PDFProtection("pw")
        var output = OutputOptions()
        XCTAssertNil(try PDFWriteOptions.forOutput(output, title: "Scan", protection: protection).protection) // the option is off
        output.protect = true
        XCTAssertThrowsError(try PDFWriteOptions.forOutput(output, title: "Scan"))
        var options = try PDFWriteOptions.forOutput(output, title: "Scan", protection: protection)
        XCTAssertEqual(options.conformance, .standard)
        XCTAssertTrue(options.isProtected)
        XCTAssertEqual(options.title, "Scan")
        XCTAssertTrue(options.protection === protection)
        // A settings file with both switches on gets the password, never an open PDF/A file.
        output.archival = true
        options = try PDFWriteOptions.forOutput(output, title: "Scan", protection: protection)
        XCTAssertEqual(options.conformance, .standard)
        XCTAssertTrue(options.isProtected)
        XCTAssertFalse(PDFWriteOptions.standard.isProtected)
    }

    func test_protected_goldenBytes() throws {
        // PdfEncryptionTests.Protected_GoldenBytes: one Letter page with a Turkish line, its key, salts
        // and IVs from the counting bytes.
        let protection = try PDFProtection("Şifre 2026")
        let pdf = try PDFWriter.make([Self.page([Self.line])], options: Self.protected(protection))
        XCTAssertEqual(pdf.count, 10030)
        XCTAssertEqual(CompanionPackage.sha256Hex(pdf).uppercased(),
                       "CFA0C44FAC59790215E53E6D3D7AD08467844D2FCF53CD6DD87875459AEFD2B1")
    }

    func test_writeFile_writesAProtectedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFEncryptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let protection = try PDFProtection("Şifre 2026")
        let url = folder.appendingPathComponent("Gizli.pdf")
        try PDFWriter.writeFile([Self.page([Self.line])], to: url, options: PDFWriteOptions(title: "Gizli", protection: protection))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Gizli.pdf"])
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(document.unlock(withPassword: "Şifre 2026"))
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("Gizli"), "PDFKit read: \(text)")
    }
}
