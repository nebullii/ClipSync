# ClipSync — Foundation API Contract (v1)

This is THE contract between the five engineers. Code only against what is listed
here. If you need something that is missing, ask the foundation owner; do not reach
into another engineer's directory.

- Package: `Packages/ClipCore` (library product `ClipCore`), Swift tools 5.9 → Swift 5 language mode.
- Platforms: macOS 14+, iOS 17+.
- `import ClipCore` gives you everything below. Models, Store, Search, Capture, Settings
  never import AppKit/UIKit.
- All store and settings APIs are `@MainActor`. Value types (`ClipDraft`, `ClipFilter`,
  `IgnoreRules`, `StoragePolicy`, ...) are `Sendable` and can be built anywhere.

---

## 0. Directory ownership

| Path | Owner |
|---|---|
| `Packages/ClipCore/` (Models, Store, Capture, Search, Settings, Support, Tests), `project.yml`, `scripts/`, `docs/API.md`, `macOS/Shared/MacContracts.swift` | Foundation |
| `macOS/App/`, `macOS/Services/` | Mac services engineer |
| `macOS/Panel/` | Mac panel UI engineer |
| `iOS/` | iOS engineer |
| `ShareExtension/`, `Packages/ClipCore/Sources/ClipCore/Intents/`, `Packages/ClipCore/Sources/ClipCore/Media/` (except `MediaContracts.swift`) | Extensions engineer |

Files marked `// PLACEHOLDER — owned by <role>` are yours to replace (keep the type
names noted in them). New Swift files you add to your folder are picked up automatically:
`scripts/build.sh mac|ios` re-runs `xcodegen generate` before each build.

Shared resource folders: `macOS/Resources/Assets.xcassets` (Mac services engineer may add
images), `iOS/Resources/Assets.xcassets` (iOS engineer). Entitlements files (`macOS/ClipSyncMac.entitlements`,
`iOS/ClipSyncIOS.entitlements`, `ShareExtension/ClipSyncShare.entitlements`) and the generated
`SupportingFiles/*/Info.plist` belong to Foundation — ask before changing `project.yml`.

---

## 1. Data model (SwiftData, CloudKit-compatible)

```swift
public enum ClipKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case text, richText, link, image, file, color, pdf
    public var id: String { get }
    public var displayName: String { get }      // "Text", "Rich Text", ...
    public var systemImageName: String { get }  // SF Symbol name
    public var isTextual: Bool { get }          // text, richText, link, color
}

@Model public final class ClipItem {
    public var id: UUID                       // default UUID()
    public var contentHash: String            // SHA-256 hex, dedup key
    public var kindRaw: String                // ClipKind raw value — use in #Predicate
    public var createdAt: Date
    public var lastUsedAt: Date               // SORT KEY: "newest first" = lastUsedAt desc
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var title: String?
    public var plainText: String?
    public var ocrText: String?               // nil = not OCR'd yet, "" = OCR'd, no text
    public var isPinned: Bool
    public var byteSize: Int
    public var deviceName: String?
    public var isLocalOnly: Bool              // byteSize > 20 MB sync cap
    public var searchText: String             // folded index, maintained by ClipStore — don't write
    public var representations: [ClipRepresentation]?   // cascade delete
    public var pinboards: [Pinboard]?                   // many-to-many, nullify

    public init(id: UUID = UUID(), contentHash: String = "", kind: ClipKind = .text,
                createdAt: Date = Date(), lastUsedAt: Date? = nil,
                sourceAppBundleID: String? = nil, sourceAppName: String? = nil,
                title: String? = nil, plainText: String? = nil, ocrText: String? = nil,
                isPinned: Bool = false, byteSize: Int = 0, deviceName: String? = nil,
                isLocalOnly: Bool = false)
}

extension ClipItem {
    public var kind: ClipKind { get set }                       // typed kindRaw
    public var sortedRepresentations: [ClipRepresentation] { get }  // by sortIndex
    public var pasteableRepresentations: [ClipRepresentation] { get } // excludes internal (thumbnail, link icon)
    public func representation(forUTI uti: String) -> ClipRepresentation?
    public var isInPinboard: Bool { get }
    public var isProtected: Bool { get }      // isPinned || isInPinboard → survives retention/clear
    public var hasLocalBlobs: Bool { get }    // any representation stored in BlobStore (not synced)
    public var displayTitle: String { get }   // title → first text line → first OCR line → kind name
    public var colorHex: String? { get }      // "#RRGGBB"/"#RRGGBBAA" for .color items
    public func refreshSearchText()           // only if you mutate text fields yourself
}

@Model public final class ClipRepresentation {
    public var uti: String
    @Attribute(.externalStorage) public var inlineData: Data?   // small payloads
    public var fileName: String?              // BlobStore name for payloads > 256 KB
    public var byteSize: Int
    public var sortIndex: Int                 // capture order; internal types start at 1000
    public var item: ClipItem?
    public init(uti: String, inlineData: Data? = nil, fileName: String? = nil,
                byteSize: Int = 0, sortIndex: Int = 0)
}
extension ClipRepresentation {
    public var isStoredInBlob: Bool { get }
    public var isInternal: Bool { get }
}

@Model public final class Pinboard {
    public var id: UUID
    public var name: String
    public var colorHex: String               // "#RRGGBB"
    public var sortOrder: Int                 // ascending display order
    public var createdAt: Date
    public var items: [ClipItem]?             // UNORDERED — use store.items(in:)
    public init(id: UUID = UUID(), name: String, colorHex: String = "#3B82F6",
                sortOrder: Int = 0, createdAt: Date = Date())
}
extension Pinboard { public var itemCount: Int { get } }

public enum ClipSchema {
    public static var models: [any PersistentModel.Type] { get }
    public static var schema: Schema { get }
}
```

Rules for everyone:
- Never read `inlineData` directly for payloads — call `store.data(for:)` (handles blobs).
- Never compare `kind` inside `#Predicate`; compare `kindRaw` with a captured `kind.rawValue`.
- Relationships are optional: always `item.pinboards ?? []`, `item.representations ?? []`.
- Never insert/delete models yourself; go through `ClipStore` so blobs, search index and
  `revision` stay correct. Reading via `@Query` is fine and encouraged.

---

## 2. Capture (pure logic, both platforms)

```swift
public struct ClipDraft: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        public var uti: String
        public var data: Data
        public init(uti: String, data: Data)
    }
    public var kind: ClipKind
    public var plainText: String?
    public var title: String?                 // nil → derived from first text line
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var representations: [Representation]   // preference order
    public var declaredTypes: [String]        // ALL pasteboard type names, incl. markers
    public var createdAt: Date
    public var deviceName: String?            // nil → store.deviceName
    public var contentHash: String?           // optional precomputed ContentHasher.hash
    public init(kind: ClipKind, plainText: String? = nil, title: String? = nil,
                sourceAppBundleID: String? = nil, sourceAppName: String? = nil,
                representations: [Representation] = [], declaredTypes: [String] = [],
                createdAt: Date = Date(), deviceName: String? = nil, contentHash: String? = nil)
    public static func text(_ text: String, sourceAppBundleID: String? = nil,
                            sourceAppName: String? = nil, createdAt: Date = Date()) -> ClipDraft
    public var totalByteSize: Int { get }
    public var isEmpty: Bool { get }
}

public enum SkipReason: String, Sendable, Equatable, Codable {
    case concealed, transient, autoGenerated, ignoredType, empty, unsupported
}
public enum ClipClassification: Sendable, Equatable {
    case skip(SkipReason)
    case kind(ClipKind)
    public var kind: ClipKind? { get }
    public var isSkipped: Bool { get }
}
public enum PasteboardTypeClassifier {
    public static func markerSkipReason(for types: [String]) -> SkipReason?
    public static func classify(types rawTypes: [String], string: String?) -> ClipClassification
    public static func isLink(_ string: String) -> Bool    // http(s)/ftp(s) with host, mailto:
    public static func isColor(_ string: String) -> Bool   // #RGB, #RRGGBB, #RRGGBBAA, rgb(), rgba()
}
```
Classification order: marker type → skip; `public.file-url` → `.file`; with visible text:
URL type + link text → `.link`, rich type (rtf/rtfd/html) → `.richText`, link text → `.link`,
color text → `.color`, image type → `.image`, else `.text`; without text: URL type → `.link`,
PDF → `.pdf`, image → `.image`, rich → `.richText`, NSColor type → `.color`, nothing → `skip(.empty)`,
unknown only → `skip(.unsupported)`.

```swift
public enum TypeNormalizer {
    public static let legacyMap: [String: String]     // "NSStringPboardType" → "public.utf8-plain-text", ...
    public static func normalize(_ type: String) -> String
    public static func normalize(_ types: [String]) -> [String]      // mapped, de-duplicated, ordered
    public static func isMarker(_ type: String) -> Bool
    public static func isStorable(_ type: String) -> Bool            // false for markers, org.nspasteboard.source, ClipUTI.ownWrite, dyn.*
    public static func normalizeRepresentations(_ representations: [ClipDraft.Representation]) -> [ClipDraft.Representation]
}

public enum ContentHasher {
    public static func normalizeText(_ text: String) -> String      // \r\n→\n, trimmed
    public static func sha256Hex(_ data: Data) -> String
    public static func sha256Hex(_ string: String) -> String
    public static func hash(kind: ClipKind, plainText: String?, representations: [ClipDraft.Representation]) -> String
    public static func hash(_ draft: ClipDraft) -> String
}
// Textual kinds hash ONLY normalized plain text (plain + rich copies of the same words dedup).
// Other kinds hash kind + all non-internal reps sorted by UTI + text.

public struct IgnoreRules: Codable, Sendable, Equatable {
    public static let defaultBundleIDs: [String]   // 1Password (incl. "com.1password.*", "com.agilebits.*"),
                                                   // Bitwarden, Keychain Access, Passwords, KeePassXC,
                                                   // LastPass, Dashlane, Proton Pass, Enpass, Strongbox (security pass)
    public var userBundleIDs: [String]
    public var includeDefaults: Bool
    public init(userBundleIDs: [String] = [], includeDefaults: Bool = true)
    public var effectiveBundleIDs: [String] { get }
    public func shouldIgnore(bundleID: String?) -> Bool   // case-insensitive; "x.y.*" = prefix rule
    public mutating func add(_ bundleID: String)
    public mutating func remove(_ bundleID: String)
    public static func normalize(_ bundleID: String) -> String
}

public enum ClipUTI {   // plain String constants
    utf8PlainText, utf16PlainText, utf16ExternalPlainText, plainText, text,
    rtf, rtfd ("com.apple.flat-rtfd"), html, url, fileURL, png, tiff, jpeg, heic, gif, image, webp,
    pdf, color ("com.apple.cocoa.pasteboard.color"),
    concealed, transient, autoGenerated, source ("org.nspasteboard.source" — NOT a skip marker),
    legacySkipTypes: Set<String>, internalPrefix ("com.thingbits.clipsync."),
    thumbnail, linkIcon, linkPreviewImage,          // internal, never pasted
    fileURLList ("com.thingbits.clipsync.file-url-list"),  // internal: ALL file URLs of a multi-file copy
    ownWrite ("com.thingbits.clipsync.own-write"),         // pasteboard marker on ClipSync's own writes
    textTypes, richTextTypes, imageTypes: Set<String>
    static func isInternal(_:) / isImage(_:) / isText(_:) / isRichText(_:) -> Bool
}

// Multi-file list format (pinned by integration): UTF-8, one absolute file:// URL per line, "\n".
public enum ClipFileList {
    public static func encode(_ urls: [URL]) -> Data
    public static func decode(_ data: Data) -> [URL]        // tolerant: file:// lines, paths, NUL, plist [String]
    public static func decode(text: String) -> [URL]
    public static func url(fromLine line: String) -> URL?
}
// Read a .file item's URLs with store.fileURLs(for:) (fileURLList → public.file-url → plainText paths).

public enum ColorParser {
    public static func normalizedHex(from string: String) -> String?    // "#1E90FF" / "#1E90FF80"
    public static func isColor(_ string: String) -> Bool
    public static func components(fromHex hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)?
}
```

---

## 3. ClipStore — the single entry point

```swift
@MainActor public final class ClipStore: ObservableObject {
    // Creation
    public static var shared: ClipStore { get }      // on-disk; CloudKit iff AppSettings.shared.cloudSyncEnabled;
                                                     // settings = AppSettings.shared
    public static func setShared(_ store: ClipStore)
    public static func makeShared(inMemory: Bool = false, cloudSync: Bool = false) -> ClipStore
    public init(container: ModelContainer, blobStore: BlobStore, location: StoreLocation,
                isInMemory: Bool, isCloudSyncActive: Bool, storeError: String? = nil)

    // State
    public let container: ModelContainer             // .modelContainer(store.container)
    public var context: ModelContext { get }         // container.mainContext
    public let blobStore: BlobStore
    public let location: StoreLocation
    public let isInMemory: Bool
    public let isCloudSyncActive: Bool
    @Published public private(set) var storeError: String?     // non-nil after a fallback → show a banner
    @Published public private(set) var lastSaveError: String?
    @Published public private(set) var revision: Int           // +1 after every mutation
    public private(set) var lastRejection: IngestRejection?
    public var settings: AppSettings?                 // ignore rules + maxHistoryCount + retention source
    public var storagePolicy: StoragePolicy           // 256 KB inline / 20 MB sync cap / 512 MB max
    public var media: MediaServices                   // default .noop
    public var deviceName: String?                    // set at launch (Host/UIDevice name)

    // Ingest
    @discardableResult public func ingest(_ draft: ClipDraft) -> ClipItem?
    @discardableResult public func ingestDetailed(_ draft: ClipDraft) -> IngestResult

    // Reading
    public func data(for representation: ClipRepresentation) -> Data?
    public func data(for item: ClipItem, uti: String) -> Data?
    public func pasteboardPayload(for item: ClipItem) -> [ClipDraft.Representation]  // non-internal, ordered
    public func fileURLs(for item: ClipItem) -> [URL]   // .file items: ClipUTI.fileURLList, else file-url reps, else plainText paths
    public func fetchItems(_ filter: ClipFilter = ClipFilter()) -> [ClipItem]        // lastUsedAt desc
    public func latestItem() -> ClipItem?
    public func item(withID id: UUID) -> ClipItem?
    public func item(withContentHash hash: String) -> ClipItem?
    public func itemCount() -> Int

    // Item mutations
    public func markUsed(_ item: ClipItem)            // lastUsedAt = now (call after paste/copy)
    public func pin(_ item: ClipItem)
    public func unpin(_ item: ClipItem)
    public func togglePin(_ item: ClipItem)
    public func setPinned(_ pinned: Bool, for item: ClipItem)
    public func setTitle(_ title: String?, for item: ClipItem)     // nil/empty → derived title
    public func setOCRText(_ text: String?, for item: ClipItem)
    public func setInternalRepresentation(_ data: Data, uti: String, for item: ClipItem) // uti must be ClipUTI.internalPrefix*
    public func delete(_ item: ClipItem)
    public func delete(_ items: [ClipItem])
    @discardableResult public func clearHistory(keepPinned: Bool = true) -> Int

    // Retention & limits (never delete pinned or pinboard items)
    @discardableResult public func applyRetention(_ policy: RetentionPolicy, now: Date = Date()) -> Int
    @discardableResult public func trimHistory(toMaxCount maxCount: Int) -> Int
    @discardableResult public func runMaintenance(now: Date = Date()) -> Int   // settings.retention + maxHistoryCount + blob GC
    @discardableResult public func removeUnreferencedBlobs() -> Int

    // Pinboards
    public func pinboards() -> [Pinboard]                          // sortOrder asc
    public func pinboard(withID id: UUID) -> Pinboard?
    @discardableResult public func createPinboard(name: String, colorHex: String = ClipConstants.defaultPinboardColorHex) -> Pinboard
    public func renamePinboard(_ board: Pinboard, to name: String)
    public func setColor(_ colorHex: String, for board: Pinboard)
    public func deletePinboard(_ board: Pinboard)                  // items stay in history
    public func reorderPinboards(_ ordered: [Pinboard])
    public func movePinboards(fromOffsets source: IndexSet, toOffset destination: Int)  // List.onMove semantics
    public func movePinboard(from: Int, to: Int)
    public func add(_ item: ClipItem, to board: Pinboard)          // idempotent
    public func remove(_ item: ClipItem, from board: Pinboard)
    public func items(in board: Pinboard) -> [ClipItem]           // lastUsedAt desc

    // Media
    public func enrich(_ item: ClipItem) async      // OCR + thumbnail (image/pdf), title + icon (link)
    public func save()
}
```

Semantics you can rely on:
- **Ingest pipeline**: ignore rules (`settings?.ignoreRules ?? IgnoreRules()`) → reject `.ignoredApp`;
  any marker in `declaredTypes` or representation UTIs → `.markerType`; reps normalized
  (`TypeNormalizer.normalizeRepresentations`); no visible text and no reps → `.empty`; larger than
  `storagePolicy.maxIngestBytes` → `.tooLarge`; hash; **existing hash → `lastUsedAt = max(now, draft.createdAt)`,
  returns the existing item (`.bumped`)**; else insert with `lastUsedAt = createdAt = draft.createdAt`,
  reps > 256 KB go to the BlobStore, `isLocalOnly = byteSize > 20 MB`; then `maxHistoryCount` trim.
- **`capturePaused` is NOT checked by the store** — the Mac monitor checks it, so manual saves
  (iOS button, share extension, intents) still work while capture is paused.
- `byteSize` = sum of representation bytes (or UTF-8 size of `plainText` when there are none).
- Retention uses `lastUsedAt` (recently re-used items survive). Protected = pinned or in any pinboard.
- Search: whitespace tokens, AND, case/diacritic/width-insensitive over title, plainText (first 20k chars),
  ocrText, sourceAppName. First token runs in SQLite; the rest in memory.
- Every mutation saves immediately. There is one main-actor context; do not create your own
  `ModelContext` for writes.
- `ClipStore.shared` reads `AppSettings.shared.cloudSyncEnabled` once — changing sync needs an app restart.

```swift
public struct ClipFilter: Sendable, Equatable {
    public var kind: ClipKind?; public var pinboardID: UUID?; public var searchText: String
    public var pinnedOnly: Bool; public var limit: Int?; public var offset: Int
    public var kinds: Set<ClipKind>? = nil      // nil = no restriction; [] = nothing; ∩ with `kind`
    public init(kind: ClipKind? = nil, pinboardID: UUID? = nil, searchText: String = "",
                pinnedOnly: Bool = false, limit: Int? = nil, offset: Int = 0)
    public init(kinds: Set<ClipKind>?, pinboardID: UUID? = nil, searchText: String = "",   // `kinds` required
                pinnedOnly: Bool = false, limit: Int? = nil, offset: Int = 0)
    public func allows(_ kind: ClipKind) -> Bool
}
// fetchItems: a one-element `kinds` runs in SQLite; a multi-kind set (and every search token
// after the first) is applied in memory while scanning the sorted result in batches, so
// offset/limit paging stays exact. Example: Text chip = ClipFilter(kinds: [.text, .richText], limit: 60).
public struct StoragePolicy: Sendable, Equatable {
    public var inlineThresholdBytes: Int   // 256 * 1024
    public var syncSizeCapBytes: Int       // 20 * 1024 * 1024
    public var maxIngestBytes: Int         // 512 * 1024 * 1024
    public static let defaultInlineThresholdBytes, defaultSyncSizeCapBytes, defaultMaxIngestBytes: Int
    public init(inlineThresholdBytes: Int = ..., syncSizeCapBytes: Int = ..., maxIngestBytes: Int = ...)
}
public enum IngestRejection: String, Sendable, Equatable { case ignoredApp, markerType, empty, tooLarge }
public enum IngestResult { case inserted(ClipItem), bumped(ClipItem), rejected(IngestRejection)
                           public var item: ClipItem? { get } }

public struct BlobStore: Sendable, Equatable {
    public let directory: URL
    public init(directory: URL)
    public static func temporary() -> BlobStore
    @discardableResult public func write(_ data: Data) throws -> String  // name = sha256 hex; idempotent
    public func read(_ fileName: String) -> Data?
    public func exists(_ fileName: String) -> Bool
    public func delete(_ fileName: String)
    public func fileURL(for fileName: String) -> URL         // Quick Look / drag-out
    public func allFileNames() -> [String]
    public static func isValidFileName(_ name: String) -> Bool
}

public struct StoreLocation: Sendable, Equatable {
    public let directory: URL; public let storeURL: URL; public let blobsDirectory: URL; public let isAppGroup: Bool
    public init(directory: URL, isAppGroup: Bool)
    public static func resolve() -> StoreLocation    // App Group/ClipSync, else Application Support/ClipSync
    public static func temporary() -> StoreLocation
}
public enum AppGroup {
    public static func containerURL() -> URL?        // nil when not entitled (macOS checks entitlement first)
    public static func userDefaults() -> UserDefaults
    public static func hasAppGroupEntitlement() -> Bool   // macOS only (#if os(macOS))
}
public enum ClipConstants {   // appGroupID, iCloudContainerID, macBundleID, iOSBundleID, shareExtensionBundleID,
                              // storeFolderName, storeFileName, blobsFolderName,
                              // defaultPinboardColorHex, pinboardPalette: [String]
}
public enum ClipText {
    public static func derivedTitle(from text: String?, maxLength: Int = 200) -> String?
    public static func normalizeLineEndings(_ text: String) -> String
}
```

### (a) Ingesting a draft (Mac monitor / iOS "Save clipboard" / share extension)

```swift
import ClipCore

@MainActor
func capture(types: [String], string: String?, payloads: [(String, Data)],
             bundleID: String?, appName: String?, store: ClipStore, settings: AppSettings) {
    guard !settings.capturePaused else { return }                      // Mac monitor only
    let classification = PasteboardTypeClassifier.classify(types: types, string: string)
    guard let kind = classification.kind else { return }               // concealed/transient/etc.
    let draft = ClipDraft(
        kind: kind,
        plainText: string,
        sourceAppBundleID: bundleID,
        sourceAppName: appName,
        representations: payloads.map { ClipDraft.Representation(uti: $0.0, data: $0.1) },
        declaredTypes: types
    )
    if let item = store.ingest(draft) {
        Task { await store.enrich(item) }    // OCR / thumbnails / link titles (no-op until Media lands)
    } else {
        print("rejected:", store.lastRejection.map { $0.rawValue } ?? "?")
    }
}
// Simplest form:
ClipStore.shared.ingest(.text("Hello", sourceAppBundleID: "com.apple.Notes", sourceAppName: "Notes"))
```

Big images: build the draft off the main actor, optionally set
`draft.contentHash = ContentHasher.hash(draft)` there, then hop to the main actor to ingest.

### (b) SwiftUI list — with `@Query` and with `ClipStore`

```swift
import SwiftUI
import SwiftData
import ClipCore

// App root (once):  WindowGroup { RootView() }.modelContainer(ClipStore.shared.container)
//                   .environmentObject(ClipStore.shared).environmentObject(AppSettings.shared)

// 1) Live @Query (auto-updates, including CloudKit changes). Rebuild the view when search changes.
struct HistoryList: View {
    @EnvironmentObject private var store: ClipStore
    @Query private var items: [ClipItem]
    private let tokens: [String]

    init(search: String, kind: ClipKind?) {
        let tokens = SearchEngine.tokens(from: search)
        self.tokens = tokens
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: SearchEngine.predicate(kind: kind, pinnedOnly: false, firstToken: tokens.first),
            sortBy: [SortDescriptor(\ClipItem.lastUsedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        _items = Query(descriptor)
    }

    var body: some View {
        let visible = items.filter { SearchEngine.matches($0, tokens: Array(tokens.dropFirst())) }
        List(visible) { item in
            Text(item.displayTitle)
                .swipeActions {
                    Button("Delete", role: .destructive) { store.delete(item) }
                    Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item) }
                }
        }
    }
}

// 2) Imperative fetch through ClipStore (refreshes on store.revision).
struct PanelStrip: View {
    @EnvironmentObject private var store: ClipStore
    @State private var search = ""
    var body: some View {
        let items = store.fetchItems(ClipFilter(searchText: search, limit: 200))
        ScrollView(.horizontal) {
            LazyHStack { ForEach(items) { Text($0.displayTitle) } }
        }
        .id(store.revision)
    }
}
```

### (c) Pinboards

```swift
let store = ClipStore.shared
let work = store.createPinboard(name: "Work", colorHex: ClipConstants.pinboardPalette[1])
if let item = store.latestItem() { store.add(item, to: work) }
let workItems = store.items(in: work)                          // or fetchItems(ClipFilter(pinboardID: work.id))
store.renamePinboard(work, to: "Office")
store.setColor("#EF4444", for: work)
// SwiftUI: List { ForEach(store.pinboards()) { Text($0.name) }.onMove { store.movePinboards(fromOffsets: $0, toOffset: $1) } }
// @Query alternative: @Query(sort: \Pinboard.sortOrder) var boards: [Pinboard]
store.deletePinboard(work)                                     // items remain in history
```

---

## 4. Search

```swift
public enum SearchEngine {
    public static let maxIndexedCharacters: Int      // 20_000
    public static func normalize(_ text: String) -> String          // "Café" → "cafe"
    public static func tokens(from query: String) -> [String]       // normalized, unique
    public static func makeSearchText(title: String?, plainText: String?, ocrText: String?, sourceAppName: String?) -> String
    public static func matches(searchText: String, tokens: [String]) -> Bool
    public static func matches(_ item: ClipItem, tokens: [String]) -> Bool
    public static func filter(_ items: [ClipItem], query: String) -> [ClipItem]
    public static func predicate(kind: ClipKind? = nil, pinnedOnly: Bool = false, firstToken: String? = nil) -> Predicate<ClipItem>
    public static func predicate(kind: ClipKind?, pinnedOnly: Bool, query: String) -> Predicate<ClipItem>
    public static func matches(_ item: ClipItem, kinds: Set<ClipKind>?) -> Bool     // in-memory multi-kind filter
    public static func sqlKind(kind: ClipKind?, kinds: Set<ClipKind>?) -> ClipKind? // single kind to push into SQL
}
// @Query + several kinds: predicate(kind: SearchEngine.sqlKind(kind: nil, kinds: set), ...) then
// filter the results with matches(_:kinds:).
```
Do not write your own `#Predicate`s over `ClipItem` text; use these. If you need a new
predicate shape, ask the foundation owner (complex predicates are the #1 compile-break risk).

---

## 5. Settings

```swift
@MainActor public final class AppSettings: ObservableObject {
    public static var shared: AppSettings { get }                 // lazily created (was `static let`)
    public static func setShared(_ settings: AppSettings)         // call before anything reads .shared / ClipStore.shared
    public static func ephemeral(suiteName: String = "com.thingbits.clipsync.ephemeral") -> AppSettings // wiped, isolated suite
    public static var allKeys: [String] { get }
    public static let defaultRetention: RetentionPolicy           // .month
    public static let defaultMaxHistoryCount: Int                 // 10_000 (0 = unlimited)
    public let defaults: UserDefaults
    public enum Keys { retention, capturePaused, cloudSyncEnabled, ignoreRules, plainTextByDefault,
                       launchAtLogin, maxHistoryCount, hasCompletedOnboarding }  // "clipsync.*" strings
    @Published public var retention: RetentionPolicy
    @Published public var capturePaused: Bool
    @Published public var cloudSyncEnabled: Bool          // applied at next launch
    @Published public var ignoreRules: IgnoreRules        // persisted as JSON
    @Published public var plainTextByDefault: Bool
    @Published public var launchAtLogin: Bool             // Mac services applies via SMAppService
    @Published public var maxHistoryCount: Int
    @Published public var hasCompletedOnboarding: Bool
    public var ignoredBundleIDs: [String] { get set }     // = ignoreRules.userBundleIDs
    public init(defaults: UserDefaults? = nil)            // nil → AppGroup.userDefaults()
    public func addIgnoredBundleID(_ bundleID: String)
    public func removeIgnoredBundleID(_ bundleID: String)
    public func resetToDefaults()
}

public enum RetentionPolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case day, week, month, year, forever
    public var id: String { get }
    public var displayName: String { get }
    public func cutoffDate(from now: Date = Date(), calendar: Calendar = Calendar.current) -> Date?
}
```

### (d) Settings usage

```swift
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ClipStore
    var body: some View {
        Form {
            Picker("Keep history", selection: $settings.retention) {
                ForEach(RetentionPolicy.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Pause capture", isOn: $settings.capturePaused)
            Toggle("Sync with iCloud (restart required)", isOn: $settings.cloudSyncEnabled)
            Toggle("Paste as plain text by default", isOn: $settings.plainTextByDefault)
            Button("Ignore Slack") { settings.addIgnoredBundleID("com.tinyspeck.slackmacgap") }
            Button("Clean up now") { store.runMaintenance() }
            if let error = store.storeError { Text(error).foregroundStyle(.red) }
        }
        .onChange(of: settings.retention) { _, _ in store.runMaintenance() }
    }
}
```

---

## 6. Media (CONTRACT — extensions engineer implements)

Declared in `Packages/ClipCore/Sources/ClipCore/Media/MediaContracts.swift` (Foundation-owned):

```swift
public protocol ThumbnailGenerating: Sendable {
    func thumbnailPNG(for data: Data, uti: String, maxPixelSize: Int) async -> Data?
    func thumbnailImage(for data: Data, uti: String, maxPixelSize: Int) async -> CGImage?
}
public protocol TextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async -> String?   // "" = no text, nil = failed/unavailable
}
public struct LinkMetadata: Sendable, Equatable {
    public var title: String?; public var iconData: Data?; public var imageData: Data?
    public init(title: String? = nil, iconData: Data? = nil, imageData: Data? = nil)
}
public protocol LinkMetadataFetching: Sendable {
    func fetchMetadata(for url: URL) async -> LinkMetadata?
}
public struct MediaServices: Sendable {
    public var thumbnails: any ThumbnailGenerating
    public var textRecognizer: any TextRecognizing
    public var linkMetadata: any LinkMetadataFetching
    public init(thumbnails:textRecognizer:linkMetadata:)
    public static var noop: MediaServices { get }
}
public struct NoopThumbnailGenerator, NoopTextRecognizer, NoopLinkMetadataFetcher   // public init()
```

The extensions engineer adds exactly these files in that folder:
- `Media/ImageIOThumbnailGenerator.swift` — `public struct ImageIOThumbnailGenerator: ThumbnailGenerating`
  (ImageIO `CGImageSourceCreateThumbnailAtIndex`; PDFs via `CGPDFDocument`/PDFKit page 1).
- `Media/VisionTextRecognizer.swift` — `public struct VisionTextRecognizer: TextRecognizing`
  (`VNRecognizeTextRequest`, `.accurate`, language correction on; run off the main actor).
- `Media/LinkPreviewFetcher.swift` — `public struct LinkPreviewFetcher: LinkMetadataFetching`
  (`LPMetadataProvider`, 10 s timeout; new provider per call; icon/image via `NSItemProvider` → Data).
- `Media/MediaServices+Live.swift` — `extension MediaServices { public static func live() -> MediaServices }`.

Apps opt in at launch: `ClipStore.shared.media = .live()`. `ClipStore.enrich(_:)` stores results as
`ClipUTI.thumbnail`, `ClipUTI.linkIcon`, `ClipUTI.linkPreviewImage` internal representations and `ocrText`.
UI reads a thumbnail with `store.data(for: item, uti: ClipUTI.thumbnail)`.
Media files may import Vision/ImageIO/LinkPresentation/PDFKit; AppKit/UIKit only inside `#if canImport(...)`.

## 7. Intents (extensions engineer)

Folder `Packages/ClipCore/Sources/ClipCore/Intents/`. Planned: `ClipItemEntity.swift`,
`SaveClipboardIntent.swift`, `SearchClipsIntent.swift`, `CopyLatestIntent.swift`, `ClipSyncShortcuts.swift`.
Use `ClipStore.shared` inside `@MainActor func perform()`. Pasteboard code under `#if canImport(UIKit)` /
`#if canImport(AppKit)`. App Intents metadata extraction from a static SwiftPM library needs
`ClipCoreAppIntentsPackage` (in ClipCore) plus one `AppIntentsPackage` per app target that includes it:
Mac = `macOS/App/ClipSyncAppIntents.swift`; iOS = same snippet (see docs/INTEGRATION_NOTES.md). Verify on
the first build; fall back to thin wrapper intents in the app targets if Shortcuts does not list them.

---

## 8. Mac service ↔ panel seam (`macOS/Shared/MacContracts.swift`)

```swift
@MainActor protocol PanelPresenting: AnyObject {
    var isVisible: Bool { get }
    func toggle(); func show(); func hide()
}
@MainActor protocol PasteActing: AnyObject {
    var hasAccessibilityPermission: Bool { get }
    func paste(_ item: ClipItem, asPlainText: Bool)            // hides panel, writes pasteboard, ⌘V, markUsed
    func copyToPasteboard(_ item: ClipItem, asPlainText: Bool) // pasteboard only, markUsed
}
@MainActor final class AppEnvironment: ObservableObject {
    let store: ClipStore
    let settings: AppSettings
    var paster: PasteActing          // default NoopPaster
    var panel: PanelPresenting       // default NoopPanelPresenter
    init(store: ClipStore, settings: AppSettings, paster: PasteActing? = nil, panel: PanelPresenting? = nil)
    static let shared: AppEnvironment   // ClipStore.shared + AppSettings.shared
}
extension KeyboardShortcuts.Name { static let togglePanel }   // default ⇧⌘V
extension Notification.Name { static let clipSyncOpenSettings }   // optional userInfo["tab"]: String =
enum ClipSyncNotificationKey { static let settingsTab = "tab" }   // "general"|"history"|"privacy"|"sync"|"about"
final class NoopPaster: PasteActing; final class NoopPanelPresenter: PanelPresenting
```

Factory seam (file in `macOS/Panel/`, placeholder written by Foundation, body owned by the panel engineer):
```swift
@MainActor enum PanelFactory {
    static func makePanel(environment: AppEnvironment) -> PanelPresenting
}
```

Launch sequence (services engineer, in `macOS/App`):
```swift
let env = AppEnvironment.shared
env.store.deviceName = Host.current().localizedName
env.paster = PasteService(environment: env)               // your PasteActing
env.panel = PanelFactory.makePanel(environment: env)      // panel engineer's PanelPresenting
KeyboardShortcuts.onKeyUp(for: .togglePanel) { env.panel.toggle() }
env.store.runMaintenance()
```
Panel side: host SwiftUI with `.modelContainer(env.store.container)`, `.environmentObject(env)`,
`.environmentObject(env.store)`, `.environmentObject(env.settings)`. To paste: `env.paster.paste(item,
asPlainText: shiftHeld || env.settings.plainTextByDefault)` — product decision: ⇧↩ ALWAYS pastes as
plain text (it does not invert the setting); ↩ uses `plainTextByDefault`. The paster hides the panel itself.
Rules: services never import Panel types; panel never touches NSPasteboard writing or CGEvent.

---

## 9. Build, signing, scripts

- First time on the Mac: `scripts/bootstrap.sh` (checks Xcode 16+, installs XcodeGen via Homebrew,
  generates `ClipSync.xcodeproj`).
- `scripts/build.sh core-test|mac|ios|all|run-mac|stop-mac|ios-sim-run|screenshot-sim|bootstrap`
  → `build/logs/<name>.log` + `build/logs/<name>.summary` (exit code + `error:` lines).
  Products: `build/DerivedData/Build/Products/Debug/ClipSync.app` (Mac),
  `.../Debug-iphonesimulator/ClipSync.app` (iOS).
- `scripts/watch.sh` (run once in Terminal): write one allow-listed word into
  `build/requests/<id>.req`; the result exit code appears in `build/requests/<id>.done`.
- Debug/Release are unsigned-friendly (Mac ad-hoc `-`, iOS Simulator no signing, no entitlements).
  For App Group / iCloud / push, set `DEVELOPMENT_TEAM` in `project.yml` → `settings.configs.Signed`
  and build with `-configuration Signed`. Unsigned builds use `Application Support/ClipSync` and
  `UserDefaults.standard`; signed builds use the App Group container and suite.
- Ad-hoc Mac builds get a new code signature each build, so macOS may ask for Accessibility again
  after rebuilding (remove + re-add ClipSync in System Settings › Privacy & Security › Accessibility).
- Sync note: payloads > 256 KB live in local blob files and do NOT sync in this build (only the item
  row and small inline payloads do). To sync images up to 20 MB, raise
  `store.storagePolicy.inlineThresholdBytes` to `StoragePolicy.defaultSyncSizeCapBytes`
  (`.externalStorage` lets CloudKit carry them as assets).

---

## 10. Security & privacy (security pass — additive; see docs/SECURITY.md)

```swift
// Settings (AppSettings, all persisted, all in allKeys)
@Published public internal(set) var appLockEnabled: Bool   // default false; change ONLY via AppLockController.setEnabled
@Published public var lockTimeout: LockTimeout             // default .after5Minutes (AppSettings.defaultLockTimeout)
@Published public var linkPreviewsEnabled: Bool            // default false — gates ClipStore.enrich link fetching
@Published public var hideFromScreenCapture: Bool          // default true (Mac NSWindow.sharingType = .none; off in UI-test mode)
@Published public var privacyCoverEnabled: Bool            // default true (iOS app-switcher cover; off in -uitest-seed)
@Published public var clearHistoryOnQuit: Bool             // default false (Mac)
// resetToDefaults() leaves appLockEnabled / lockTimeout alone.

public enum LockTimeout: String, CaseIterable, Codable, Sendable, Identifiable {
    case immediately, after1Minute, after5Minutes, after15Minutes, after1Hour
    var displayName: String; var interval: TimeInterval?    // nil = lock when hidden
}
public enum BiometryKind { case none, touchID, faceID, opticID; var displayName: String?; var systemImageName: String }

@MainActor public final class AppLockController: ObservableObject {
    static var shared: AppLockController                    // AppSettings.shared + LocalAuthentication; read after AppSettings.setShared
    static func setShared(_:)
    static func makeSystemAuthenticator() -> AppLockAuthenticating
    init(settings: AppSettings, authenticator: AppLockAuthenticating, clock: AppLockClock? = nil)
    @Published private(set) var isLocked: Bool              // starts = settings.appLockEnabled
    @Published private(set) var isAuthenticating, canAuthenticate: Bool; biometryKind: BiometryKind; lastMessage: String?
    var autoPromptOnShow: Bool                               // apps set false in UI-test mode
    var isEnabled: Bool; var timeout: LockTimeout; var unlockButtonTitle: String
    func unlock(reason:) async -> Bool                       // .deviceOwnerAuthentication (biometrics + password/passcode)
    func lockNow(); func noteActivity(); func noteInterfaceHidden(); @discardableResult func checkTimeout() -> Bool
    func setEnabled(_:reason:) async -> AppLockChangeResult  // both directions authenticate; on refused without passcode
    func addLockStateObserver(_: @escaping @MainActor (Bool) -> Void)   // called synchronously after each change
    #if DEBUG  func enableForTesting(); func unlockAndDisableForTesting()  #endif
}
@MainActor public protocol AppLockAuthenticating: AnyObject { availability(); authenticate(reason:) async -> AppLockAuthResult }
public protocol AppLockClock: AnyObject { func now() -> TimeInterval }   // ContinuousAppLockClock (counts during sleep)

ClipIntentError.locked                                       // "ClipSync is locked. Unlock it in the app, then try again."
ClipIntentRunner.requireUnlocked() throws                    // every READING intent / entity query calls it; save intents don't
ClipStore.linkFetchAttempts: Int                             // calls to media.linkMetadata (0 while previews are off)
ClipStore.clearHistory(...)                                  // now also runs removeUnreferencedBlobs()
public enum StoreFileProtection                              // 0700 dirs / 0600 files; iOS completeUntilFirstUserAuthentication
                                                             // protectTree(at:), protectFile(_:), writeOptions, permissions(of:)
// StoreLocation.resolve() and ClipStore.makeShared() call protectTree; BlobStore.write protects each file.
```

Mac seam: `AppEnvironment.appLock` (default `AppLockController.shared`). While `appLock.isLocked` the panel
shows only `PanelLockView`, `PanelViewModel` holds no rows, and `PasteService` writes nothing.
`SettingsTab.security` ("security") is a new deep-link value for `.clipSyncOpenSettings`.
