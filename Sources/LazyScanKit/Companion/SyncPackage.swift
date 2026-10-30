import CryptoKit
import Foundation

// Twin of windows/LazyScan.Core/Companion/SyncPackage.cs: the same bytes for the same package,
// key and nonce, and the same checks when opening one.

/// Why a `.cssync` file could not be made or opened.
public enum SyncPackageError: Error, Equatable, LocalizedError, Sendable {
    /// Too short, or not starting with `SyncPackage.magic`.
    case notASyncPackage
    /// A newer format version than this app reads.
    case newerVersion
    /// Sealed with another key, for another package id or phone, or changed since.
    case wrongKeyOrTampered
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .notASyncPackage: return "This file was not put in the cloud folder by Lazy Scan."
        case .newerVersion: return "This file was put in the cloud folder by a newer version of Lazy Scan."
        case .wrongKeyOrTampered: return "This file was not put there by a phone paired with this computer, or it was changed."
        case .tooLarge: return CompanionError.tooLarge.message
        }
    }
}

/// A `.lsdoc` package sealed for the cloud sync folder (C2): what a phone writes into a folder the user
/// syncs (iCloud Drive, OneDrive) when the desktop cannot be reached, as "<packageId>.cssync". The bytes
/// are `magic`, a 16-byte header (version, target, two reserved zero bytes, the 12-byte nonce) and the
/// package encrypted with AES-256-GCM under the sync key the desktop handed out at pairing, its 16-byte
/// tag last. The magic and header, the package id and the phone's id are authenticated with it, so a
/// file renamed, moved to another phone's name or changed in any byte does not open.
public enum SyncPackage {
    public static let fileExtension = "cssync"
    public static let version = 1
    public static let keyByteCount = 32
    public static let nonceByteCount = 12
    public static let tagByteCount = 16
    public static let headerByteCount = 16
    /// "CSSYNC01".
    public static let magic = Data("CSSYNC01".utf8)

    /// The largest file opened: a package as large as an upload may be, plus the framing.
    public static var maxFileBytes: Int { CompanionProtocol.maxUploadBytes + 64 }

    /// `plaintext` (a `.lsdoc`) sealed under `key` with `nonce` (a random one when nil). Throws
    /// `SyncPackageError.tooLarge` for a package larger than an upload may be.
    public static func seal(packageId: String, phoneId: String, target: CompanionTarget, plaintext: Data, key: Data,
                            nonce: Data? = nil) throws -> Data {
        guard plaintext.count <= CompanionProtocol.maxUploadBytes else { throw SyncPackageError.tooLarge }
        let nonce = try AES.GCM.Nonce(data: nonce ?? Data(AES.GCM.Nonce()))
        var output = magic
        output.append(UInt8(version))
        output.append(UInt8(target == .current ? 1 : 0))
        output.append(contentsOf: [0, 0])
        output.append(contentsOf: nonce)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce,
                                   authenticating: associatedData(output, packageId: packageId, phoneId: phoneId))
        output.append(box.ciphertext)
        output.append(box.tag)
        return output
    }

    /// The package sealed in `data` for `packageId` by `phoneId`, and where it goes. Throws `SyncPackageError`.
    public static func open(_ data: Data, packageId: String, phoneId: String,
                            key: Data) throws -> (target: CompanionTarget, plaintext: Data) {
        guard data.count <= maxFileBytes else { throw SyncPackageError.tooLarge }
        let bytes = [UInt8](data)
        let prefix = magic.count + headerByteCount
        guard bytes.count >= prefix + tagByteCount, Data(bytes[0..<magic.count]) == magic, bytes[magic.count] != 0 else {
            throw SyncPackageError.notASyncPackage
        }
        guard Int(bytes[magic.count]) <= version else { throw SyncPackageError.newerVersion }
        guard key.count == keyByteCount else { throw SyncPackageError.wrongKeyOrTampered }
        let target: CompanionTarget = bytes[magic.count + 1] == 1 ? .current : .new
        let nonceStart = magic.count + 4
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: bytes[nonceStart..<nonceStart + nonceByteCount]),
                                            ciphertext: bytes[prefix..<bytes.count - tagByteCount],
                                            tag: bytes[(bytes.count - tagByteCount)...])
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key),
                                             authenticating: associatedData(Data(bytes[0..<prefix]), packageId: packageId,
                                                                            phoneId: phoneId))
            return (target, plaintext)
        } catch {
            throw SyncPackageError.wrongKeyOrTampered
        }
    }

    /// The file name a package is put in the folder under.
    public static func fileName(_ packageId: String) -> String {
        packageId + "." + fileExtension
    }

    /// The magic and header, the package id, a zero byte and the phone's id.
    private static func associatedData(_ prefix: Data, packageId: String, phoneId: String) -> Data {
        var data = prefix
        data.append(contentsOf: Array(packageId.utf8))
        data.append(0)
        data.append(contentsOf: Array(phoneId.utf8))
        return data
    }
}
