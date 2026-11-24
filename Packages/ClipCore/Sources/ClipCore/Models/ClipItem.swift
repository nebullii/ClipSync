import Foundation
import SwiftData

/// One clipboard history entry.
///
/// CloudKit-compatible: every stored property has a default or is optional,
/// no unique attributes, relationships are optional with explicit inverses.
@Model
public final class ClipItem {
    /// Stable identity (not unique-constrained; CloudKit forbids that).
    public var id: UUID = UUID()
    /// SHA-256 hex of the normalized content (see `ContentHasher`). Used for dedup.
    public var contentHash: String = ""
    /// Raw value of `ClipKind`. Use `kind` in code; use `kindRaw` inside `#Predicate`.
    public var kindRaw: String = "text"
    public var createdAt: Date = Date()
    /// Sort key for "most recent first". Bumped by dedup and `markUsed`.
    public var lastUsedAt: Date = Date()
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var title: String?
    public var plainText: String?
    /// Vision OCR text for images. nil = not processed yet, "" = processed, no text.
    public var ocrText: String?
    public var isPinned: Bool = false
    /// Total payload size in bytes (representations, or plain text when there are none).
    public var byteSize: Int = 0
    public var deviceName: String?
    /// True when `byteSize` exceeds the sync size cap (20 MB): the content stays on this device.
    public var isLocalOnly: Bool = false
    /// Normalized (case/diacritic-folded) text of title + plainText + ocrText + sourceAppName.
    /// Maintained by ClipStore; used by `SearchEngine`. Do not set directly.
    public var searchText: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ClipRepresentation.item)
    public var representations: [ClipRepresentation]? = []

    @Relationship(deleteRule: .nullify, inverse: \Pinboard.items)
    public var pinboards: [Pinboard]? = []

    public init(
        id: UUID = UUID(),
        contentHash: String = "",
        kind: ClipKind = .text,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        title: String? = nil,
        plainText: String? = nil,
        ocrText: String? = nil,
        isPinned: Bool = false,
        byteSize: Int = 0,
        deviceName: String? = nil,
        isLocalOnly: Bool = false
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.title = title
        self.plainText = plainText
        self.ocrText = ocrText
        self.isPinned = isPinned
        self.byteSize = byteSize
        self.deviceName = deviceName
        self.isLocalOnly = isLocalOnly
        self.searchText = SearchEngine.makeSearchText(
            title: title,
            plainText: plainText,
            ocrText: ocrText,
            sourceAppName: sourceAppName
        )
    }
}

// MARK: - Convenience (non-stored)

extension ClipItem {
    /// Typed accessor over `kindRaw`.
    public var kind: ClipKind {
        get { return ClipKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    /// Representations in capture order (internal ClipSync types last).
    public var sortedRepresentations: [ClipRepresentation] {
        return (representations ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    /// Representations to write back to a pasteboard (excludes thumbnails/link icons).
    public var pasteableRepresentations: [ClipRepresentation] {
        return sortedRepresentations.filter { !ClipUTI.isInternal($0.uti) }
    }

    /// First representation with exactly this UTI.
    public func representation(forUTI uti: String) -> ClipRepresentation? {
        return sortedRepresentations.first { $0.uti == uti }
    }

    /// True when the item belongs to at least one pinboard.
    public var isInPinboard: Bool {
        return !(pinboards ?? []).isEmpty
    }

    /// True when the item is protected from retention cleanup / clear history.
    public var isProtected: Bool {
        return isPinned || isInPinboard
    }

    /// True when any representation's bytes live in the local BlobStore (not synced).
    public var hasLocalBlobs: Bool {
        return (representations ?? []).contains { $0.fileName != nil }
    }

    /// Best human-readable one-liner: title, else first text line, else kind name.
    public var displayTitle: String {
        if let title = title, !title.isEmpty { return title }
        if let derived = ClipText.derivedTitle(from: plainText) { return derived }
        if let ocr = ClipText.derivedTitle(from: ocrText) { return ocr }
        return kind.displayName
    }

    /// Normalized "#RRGGBB"/"#RRGGBBAA" for color items (nil otherwise).
    public var colorHex: String? {
        guard kind == .color, let text = plainText else { return nil }
        return ColorParser.normalizedHex(from: text)
    }

    /// Recomputes `searchText`. ClipStore calls this; call it yourself only if you
    /// mutate title/plainText/ocrText/sourceAppName without going through ClipStore.
    public func refreshSearchText() {
        searchText = SearchEngine.makeSearchText(
            title: title,
            plainText: plainText,
            ocrText: ocrText,
            sourceAppName: sourceAppName
        )
    }
}
