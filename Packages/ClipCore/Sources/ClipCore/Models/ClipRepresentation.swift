import Foundation
import SwiftData

/// One pasteboard flavor of a `ClipItem` (e.g. public.utf8-plain-text, public.png).
///
/// Small payloads live in `inlineData`; payloads above the inline threshold
/// (~256 KB) live in the `BlobStore` and are referenced by `fileName`.
/// Read the bytes with `ClipStore.data(for:)`, which handles both cases.
@Model
public final class ClipRepresentation {
    /// Normalized uniform type identifier.
    public var uti: String = ""
    @Attribute(.externalStorage)
    public var inlineData: Data? = nil
    /// BlobStore file name (SHA-256 hex of the bytes) when stored out of line.
    public var fileName: String? = nil
    public var byteSize: Int = 0
    /// Capture order; lower = preferred.
    public var sortIndex: Int = 0
    /// Inverse of `ClipItem.representations`.
    public var item: ClipItem? = nil

    public init(
        uti: String,
        inlineData: Data? = nil,
        fileName: String? = nil,
        byteSize: Int = 0,
        sortIndex: Int = 0
    ) {
        self.uti = uti
        self.inlineData = inlineData
        self.fileName = fileName
        self.byteSize = byteSize
        self.sortIndex = sortIndex
    }
}

extension ClipRepresentation {
    /// True when the bytes are in the BlobStore rather than inline.
    public var isStoredInBlob: Bool {
        return fileName != nil
    }

    /// True for ClipSync-private types (thumbnails, link icons) that must not be pasted.
    public var isInternal: Bool {
        return ClipUTI.isInternal(uti)
    }
}
