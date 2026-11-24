import Foundation

/// Byte-size rules applied by `ClipStore.ingest(_:)`.
public struct StoragePolicy: Sendable, Equatable {
    /// Representations larger than this go to the BlobStore instead of inline (default 256 KB).
    public var inlineThresholdBytes: Int
    /// Items larger than this are flagged `isLocalOnly` (default 20 MB).
    public var syncSizeCapBytes: Int
    /// Drafts larger than this are rejected outright (default 512 MB).
    public var maxIngestBytes: Int

    public static let defaultInlineThresholdBytes = 256 * 1024
    public static let defaultSyncSizeCapBytes = 20 * 1024 * 1024
    public static let defaultMaxIngestBytes = 512 * 1024 * 1024

    public init(
        inlineThresholdBytes: Int = StoragePolicy.defaultInlineThresholdBytes,
        syncSizeCapBytes: Int = StoragePolicy.defaultSyncSizeCapBytes,
        maxIngestBytes: Int = StoragePolicy.defaultMaxIngestBytes
    ) {
        self.inlineThresholdBytes = inlineThresholdBytes
        self.syncSizeCapBytes = syncSizeCapBytes
        self.maxIngestBytes = maxIngestBytes
    }
}

/// Filter for `ClipStore.fetchItems(_:)`. Results are sorted by `lastUsedAt`, newest first.
public struct ClipFilter: Sendable, Equatable {
    /// Only this kind (nil = all kinds).
    public var kind: ClipKind?
    /// Only items in this pinboard (nil = whole history).
    public var pinboardID: UUID?
    /// Free text; whitespace-separated tokens are AND-ed, case/diacritic-insensitive.
    public var searchText: String
    /// Only `isPinned` items.
    public var pinnedOnly: Bool
    /// Max results (nil = no limit).
    public var limit: Int?
    /// Results to skip (for paging).
    public var offset: Int
    /// Only these kinds (nil = no restriction; an empty set matches nothing).
    /// Combined with `kind` by intersection when both are set. Added by the integration
    /// pass (additive); use `init(kinds:...)` or set the property.
    public var kinds: Set<ClipKind>? = nil

    /// Multi-kind filter (e.g. Text = [.text, .richText]). `kinds` has no default here,
    /// so this never competes with `init(kind:...)` during overload resolution.
    public init(
        kinds: Set<ClipKind>?,
        pinboardID: UUID? = nil,
        searchText: String = "",
        pinnedOnly: Bool = false,
        limit: Int? = nil,
        offset: Int = 0
    ) {
        self.kind = nil
        self.pinboardID = pinboardID
        self.searchText = searchText
        self.pinnedOnly = pinnedOnly
        self.limit = limit
        self.offset = offset
        self.kinds = kinds
    }

    /// True when `kind` passes both `kind` and `kinds`.
    public func allows(_ kind: ClipKind) -> Bool {
        if let single = self.kind, single != kind { return false }
        if let set = kinds, !set.contains(kind) { return false }
        return true
    }

    public init(
        kind: ClipKind? = nil,
        pinboardID: UUID? = nil,
        searchText: String = "",
        pinnedOnly: Bool = false,
        limit: Int? = nil,
        offset: Int = 0
    ) {
        self.kind = kind
        self.pinboardID = pinboardID
        self.searchText = searchText
        self.pinnedOnly = pinnedOnly
        self.limit = limit
        self.offset = offset
    }
}

/// Why `ClipStore.ingest(_:)` returned nil.
public enum IngestRejection: String, Sendable, Equatable {
    /// Source app matched the ignore rules.
    case ignoredApp
    /// A concealed / transient / auto-generated (or legacy) marker type was present.
    case markerType
    /// No visible text and no non-empty representation.
    case empty
    /// Larger than `StoragePolicy.maxIngestBytes`.
    case tooLarge
}

/// Detailed outcome of `ClipStore.ingestDetailed(_:)`.
public enum IngestResult {
    /// A new item was created.
    case inserted(ClipItem)
    /// An item with the same content hash existed and was bumped to the top.
    case bumped(ClipItem)
    case rejected(IngestRejection)

    /// The created or bumped item, nil when rejected.
    public var item: ClipItem? {
        switch self {
        case .inserted(let item): return item
        case .bumped(let item): return item
        case .rejected: return nil
        }
    }
}
