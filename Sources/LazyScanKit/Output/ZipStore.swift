import Foundation

// Twin of windows/LazyScan.Core/ZipStore.cs: the same bytes for the same entries.

/// One file in a zip package: its path inside the package ("word/document.xml") and its bytes.
public struct ZipStoreEntry {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// A minimal zip writer for the Word document (`DocxWriter`): every entry stored uncompressed
/// (Word and LibreOffice read stored entries), dated 1980-01-01, in the order given, with a CRC-32
/// per entry. Foundation has no zip writer; this writes the very same bytes as the Windows app.
/// No zip64: a package must stay under 4 GB and 65,535 entries.
public enum ZipStore {
    /// The CRC-32 of zip and PNG (polynomial 0xEDB88320, reflected; "123456789" gives 0xCBF43926).
    public static func crc32<Bytes: Sequence>(_ data: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The size in bytes of the package `make` writes for `entries`, worked out without writing it:
    /// a caller checks a large package against its limit first (`make` stops the app on a package
    /// past 4 GB).
    public static func packageSize(_ entries: [ZipStoreEntry]) -> Int {
        var size = endRecordSize
        for entry in entries {
            let name = entry.name.utf8.count
            size += localHeaderSize + name + entry.data.count + centralRecordSize + name
        }
        return size
    }

    /// The zip package holding `entries`, in that order.
    public static func make(_ entries: [ZipStoreEntry]) -> Data {
        precondition(entries.count <= Int(UInt16.max), "Too many entries for a zip without zip64.")
        var output = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let utf8Name = entry.name.unicodeScalars.contains { $0.value > 0x7F }
            let flags: UInt16 = utf8Name ? 0x0800 : 0
            let crc = crc32(entry.data)
            let offset = output.count
            precondition(offset <= Int(UInt32.max) && entry.data.count <= Int(UInt32.max),
                         "The package is too large for a zip without zip64.")

            // Local file header.
            append32(&output, 0x0403_4B50)
            append16(&output, versionNeeded)
            append16(&output, flags)
            append16(&output, 0) // stored
            append16(&output, dosTime)
            append16(&output, dosDate)
            append32(&output, crc)
            append32(&output, UInt32(entry.data.count))
            append32(&output, UInt32(entry.data.count))
            append16(&output, UInt16(name.count))
            append16(&output, 0) // no extra field
            output.append(name)
            output.append(entry.data)

            // Its central directory record.
            append32(&central, 0x0201_4B50)
            append16(&central, versionMadeBy)
            append16(&central, versionNeeded)
            append16(&central, flags)
            append16(&central, 0)
            append16(&central, dosTime)
            append16(&central, dosDate)
            append32(&central, crc)
            append32(&central, UInt32(entry.data.count))
            append32(&central, UInt32(entry.data.count))
            append16(&central, UInt16(name.count))
            append16(&central, 0) // extra field
            append16(&central, 0) // comment
            append16(&central, 0) // disk number
            append16(&central, 0) // internal attributes
            append32(&central, 0) // external attributes
            append32(&central, UInt32(offset))
            central.append(name)
        }

        let centralOffset = output.count
        output.append(central)
        precondition(output.count <= Int(UInt32.max), "The package is too large for a zip without zip64.")

        // End of central directory.
        append32(&output, 0x0605_4B50)
        append16(&output, 0) // this disk
        append16(&output, 0) // the disk the directory starts on
        append16(&output, UInt16(entries.count))
        append16(&output, UInt16(entries.count))
        append32(&output, UInt32(central.count))
        append32(&output, UInt32(centralOffset))
        append16(&output, 0) // no comment
        return output
    }

    /// 1.0: stored entries need nothing newer.
    private static let versionNeeded: UInt16 = 10
    /// 2.0, MS-DOS attributes.
    private static let versionMadeBy: UInt16 = 20
    /// 00:00:00.
    private static let dosTime: UInt16 = 0
    /// 1980-01-01, the earliest date a zip can hold: the same bytes on every save.
    private static let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1
    /// The fixed part of a local file header, a central directory record and the end record.
    private static let localHeaderSize = 30
    private static let centralRecordSize = 46
    private static let endRecordSize = 22

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func append16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func append32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8(value >> 24))
    }
}
