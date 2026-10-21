#if os(iOS)
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A photo from the Photos picker as its file's own bytes: HEIC, JPEG or PNG as stored, never turned
/// into another format (SwiftUI's `Image` carries only PNG and JPEG, and would drop the original
/// pixels and the orientation tag). The picker asks for the current encoding (`.current`), and runs
/// in its own process, so the app needs no access to the photo library.
public struct IOSPickedImage: Transferable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: UTType.image) { (data: Data) -> IOSPickedImage in
            IOSPickedImage(data: data)
        }
    }
}
#endif
