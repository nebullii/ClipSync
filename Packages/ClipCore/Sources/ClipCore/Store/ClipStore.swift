import Foundation
import SwiftData
import Combine

/// The single entry point to ClipSync data. Wraps one `ModelContainer` and its
/// main `ModelContext`. Every mutation saves immediately and bumps `revision`.
///
/// Create it once per process (`ClipStore.shared` or `makeShared(...)`) and inject it.
/// For SwiftUI `@Query`, attach `.modelContainer(store.container)`.
@MainActor
public final class ClipStore: ObservableObject {

    // MARK: - Shared instance

    private static var sharedStore: ClipStore?

    /// Lazily created process-wide store: on-disk, CloudKit per
    /// `AppSettings.shared.cloudSyncEnabled`, `settings` = `AppSettings.shared`.
    public static var shared: ClipStore {
        if let store = sharedStore {
            return store
        }
        let store = makeShared(inMemory: false, cloudSync: AppSettings.shared.cloudSyncEnabled)
        store.settings = AppSettings.shared
        sharedStore = store
        return store
    }

    /// Replaces the instance returned by `shared` (call once at launch if you built
    /// your own store, e.g. in-memory for UI tests/previews).
    public static func setShared(_ store: ClipStore) {
        sharedStore = store
    }

    /// Builds a store. Never crashes on ordinary failures:
    /// CloudKit failure → local-only; local failure → in-memory. Inspect `storeError`.
    /// - Parameters:
    ///   - inMemory: nothing is written to disk (tests, previews). Blobs go to a temp folder.
    ///   - cloudSync: use the private CloudKit database `iCloud.com.thingbits.clipsync`.
    public static func makeShared(inMemory: Bool = false, cloudSync: Bool = false) -> ClipStore {
        let schema = ClipSchema.schema
        if inMemory {
            return makeInMemory(schema: schema, error: nil)
        }

        let location = StoreLocation.resolve()
        let blobs = BlobStore(directory: location.blobsDirectory)
        var errors: [String] = []

        // Never hand CloudKit to an unentitled process (it would crash): see CloudBuildSupport.
        let cloudKitAllowed = CloudBuildSupport.isCloudKitAvailable
        if cloudSync && !cloudKitAllowed {
            errors.append("iCloud sync is on, but this build of ClipSync is not signed for iCloud, so history stays on this device.")
        }

        if cloudSync && cloudKitAllowed {
            do {
                let config = ModelConfiguration(
                    "ClipSync",
                    schema: schema,
                    url: location.storeURL,
                    cloudKitDatabase: .private(ClipConstants.iCloudContainerID)
                )
                let container = try ModelContainer(for: schema, configurations: config)
                StoreFileProtection.protectTree(at: location.directory)
                return ClipStore(
                    container: container,
                    blobStore: blobs,
                    location: location,
                    isInMemory: false,
                    isCloudSyncActive: true,
                    storeError: nil
                )
            } catch {
                errors.append("iCloud sync unavailable, using local storage: \(error.localizedDescription)")
            }
        }

        do {
            let config = ModelConfiguration(
                "ClipSync",
                schema: schema,
                url: location.storeURL,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: config)
            // The database files may have just been created with default permissions.
            StoreFileProtection.protectTree(at: location.directory)
            return ClipStore(
                container: container,
                blobStore: blobs,
                location: location,
                isInMemory: false,
                isCloudSyncActive: false,
                storeError: errors.isEmpty ? nil : errors.joined(separator: "\n")
            )
        } catch {
            errors.append("Could not open the history database, using temporary memory-only storage: \(error.localizedDescription)")
        }

        return makeInMemory(schema: schema, error: errors.joined(separator: "\n"))
    }

    private static func makeInMemory(schema: Schema, error: String?) -> ClipStore {
        let location = StoreLocation.temporary()
        let config = ModelConfiguration(
            UUID().uuidString,
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch let inMemoryError {
            // Only reachable if the schema itself is invalid — a programming error
            // that no fallback can recover from.
            fatalError("ClipCore: cannot create an in-memory ModelContainer: \(inMemoryError)")
        }
        return ClipStore(
            container: container,
            blobStore: BlobStore(directory: location.blobsDirectory),
            location: location,
            isInMemory: true,
            isCloudSyncActive: false,
            storeError: error
        )
    }

    // MARK: - State

    /// Attach to SwiftUI with `.modelContainer(store.container)`.
    public let container: ModelContainer
    /// Large-payload file storage.
    public let blobStore: BlobStore
    /// Where the store lives on disk.
    public let location: StoreLocation
    /// True for in-memory stores (explicit or fallback).
    public let isInMemory: Bool
    /// True when the container was created with CloudKit sync.
    public let isCloudSyncActive: Bool

    /// Non-nil when creation fell back (CloudKit → local, or disk → memory). Show it in UI.
    @Published public private(set) var storeError: String? = nil
    /// Last save failure message, if any.
    @Published public private(set) var lastSaveError: String? = nil
    /// Incremented after every mutation (for views that do not use `@Query`).
    @Published public private(set) var revision: Int = 0
    /// Why the most recent `ingest` returned nil (nil after a successful ingest).
    public private(set) var lastRejection: IngestRejection?

    /// Source of ignore rules and max history count. nil = defaults.
    public var settings: AppSettings?
    /// Inline/blob threshold and size caps.
    public var storagePolicy = StoragePolicy()
    /// Thumbnail / OCR / link-preview services used by `enrich(_:)`. Default: no-op.
    public var media: MediaServices = .noop
    /// Stamped on new items. Set by platform code (Host / UIDevice name).
    public var deviceName: String?
    /// How many times `enrich(_:)` called `media.linkMetadata` (the app's only network
    /// use). Stays 0 while `settings.linkPreviewsEnabled` is off. Diagnostics / tests.
    public private(set) var linkFetchAttempts = 0

    /// The main-actor context all store operations use.
    public var context: ModelContext {
        return container.mainContext
    }

    /// Designated initializer (prefer `makeShared` / `shared`).
    public init(
        container: ModelContainer,
        blobStore: BlobStore,
        location: StoreLocation,
        isInMemory: Bool,
        isCloudSyncActive: Bool,
        storeError: String? = nil
    ) {
        self.container = container
        self.blobStore = blobStore
        self.location = location
        self.isInMemory = isInMemory
        self.isCloudSyncActive = isCloudSyncActive
        self.storeError = storeError
    }

    // MARK: - Ingest

    /// Records a draft. Returns the new item, or the existing item with the same
    /// content hash (bumped to the top), or nil when rejected (see `lastRejection`).
    @discardableResult
    public func ingest(_ draft: ClipDraft) -> ClipItem? {
        return ingestDetailed(draft).item
    }

    /// Like `ingest(_:)` but tells you whether the item was inserted, bumped or rejected.
    @discardableResult
    public func ingestDetailed(_ draft: ClipDraft) -> IngestResult {
        let rules = settings?.ignoreRules ?? IgnoreRules()
        if rules.shouldIgnore(bundleID: draft.sourceAppBundleID) {
            return reject(.ignoredApp)
        }

        let allTypes = draft.declaredTypes + draft.representations.map { $0.uti }
        if PasteboardTypeClassifier.markerSkipReason(for: allTypes) != nil {
            return reject(.markerType)
        }

        let reps = TypeNormalizer.normalizeRepresentations(draft.representations)
        let trimmedText = (draft.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty && reps.isEmpty {
            return reject(.empty)
        }

        let repBytes = reps.reduce(0) { $0 + $1.data.count }
        let totalBytes = repBytes > 0 ? repBytes : (draft.plainText?.utf8.count ?? 0)
        if totalBytes > storagePolicy.maxIngestBytes {
            return reject(.tooLarge)
        }

        let hash = draft.contentHash ?? ContentHasher.hash(kind: draft.kind, plainText: draft.plainText, representations: reps)

        if let existing = item(withContentHash: hash) {
            existing.lastUsedAt = max(Date(), draft.createdAt)
            if existing.sourceAppBundleID == nil && draft.sourceAppBundleID != nil {
                existing.sourceAppBundleID = draft.sourceAppBundleID
                existing.sourceAppName = draft.sourceAppName
                existing.refreshSearchText()
            }
            lastRejection = nil
            persist()
            return .bumped(existing)
        }

        let title = draft.title ?? ClipText.derivedTitle(from: draft.plainText)
        let newItem = ClipItem(
            contentHash: hash,
            kind: draft.kind,
            createdAt: draft.createdAt,
            lastUsedAt: draft.createdAt,
            sourceAppBundleID: draft.sourceAppBundleID,
            sourceAppName: draft.sourceAppName,
            title: title,
            plainText: draft.plainText,
            byteSize: totalBytes,
            deviceName: draft.deviceName ?? deviceName,
            isLocalOnly: totalBytes > storagePolicy.syncSizeCapBytes
        )
        context.insert(newItem)

        var models: [ClipRepresentation] = []
        for (index, rep) in reps.enumerated() {
            let model = makeRepresentation(uti: rep.uti, data: rep.data, sortIndex: index)
            context.insert(model)
            models.append(model)
        }
        newItem.representations = models

        lastRejection = nil
        persist()
        trimHistoryIfNeeded()
        return .inserted(newItem)
    }

    private func reject(_ reason: IngestRejection) -> IngestResult {
        lastRejection = reason
        return .rejected(reason)
    }

    private func makeRepresentation(uti: String, data: Data, sortIndex: Int) -> ClipRepresentation {
        if data.count > storagePolicy.inlineThresholdBytes {
            do {
                let name = try blobStore.write(data)
                return ClipRepresentation(uti: uti, inlineData: nil, fileName: name, byteSize: data.count, sortIndex: sortIndex)
            } catch {
                // Disk problem: fall back to inline (external) storage.
            }
        }
        return ClipRepresentation(uti: uti, inlineData: data, fileName: nil, byteSize: data.count, sortIndex: sortIndex)
    }

    // MARK: - Reading

    /// Bytes of a representation, whether inline or in the BlobStore.
    public func data(for representation: ClipRepresentation) -> Data? {
        if let inline = representation.inlineData {
            return inline
        }
        if let name = representation.fileName {
            return blobStore.read(name)
        }
        return nil
    }

    /// Bytes of the item's first representation with this UTI.
    public func data(for item: ClipItem, uti: String) -> Data? {
        guard let rep = item.representation(forUTI: uti) else { return nil }
        return data(for: rep)
    }

    /// (uti, bytes) pairs to write to a pasteboard, in preference order, excluding internal types.
    public func pasteboardPayload(for item: ClipItem) -> [ClipDraft.Representation] {
        var result: [ClipDraft.Representation] = []
        for rep in item.pasteableRepresentations {
            if let bytes = data(for: rep) {
                result.append(ClipDraft.Representation(uti: rep.uti, data: bytes))
            }
        }
        return result
    }

    /// Items matching `filter`, newest (`lastUsedAt`) first.
    public func fetchItems(_ filter: ClipFilter = ClipFilter()) -> [ClipItem] {
        let tokens = SearchEngine.tokens(from: filter.searchText)

        if let pinboardID = filter.pinboardID {
            guard let board = pinboard(withID: pinboardID) else { return [] }
            var list = items(in: board)
            if let kind = filter.kind {
                let raw = kind.rawValue
                list = list.filter { $0.kindRaw == raw }
            }
            if filter.kinds != nil {
                list = list.filter { SearchEngine.matches($0, kinds: filter.kinds) }
            }
            if filter.pinnedOnly {
                list = list.filter { $0.isPinned }
            }
            if !tokens.isEmpty {
                list = list.filter { SearchEngine.matches($0, tokens: tokens) }
            }
            return ClipStore.page(list, offset: filter.offset, limit: filter.limit)
        }

        // A one-element `kinds` set (and/or `kind`) goes into SQLite; a multi-kind set is
        // applied in memory below.
        let sqlKind = SearchEngine.sqlKind(kind: filter.kind, kinds: filter.kinds)
        if let kinds = filter.kinds, kinds.isEmpty { return [] }
        if let sqlKind = sqlKind, !filter.allows(sqlKind) { return [] }   // kind ∉ kinds
        let needsKindFilter = (filter.kinds?.count ?? 0) > 1

        let predicate = SearchEngine.predicate(kind: sqlKind, pinnedOnly: filter.pinnedOnly, firstToken: tokens.first)
        var descriptor = FetchDescriptor<ClipItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\ClipItem.lastUsedAt, order: .reverse)]
        )

        if tokens.count <= 1 && !needsKindFilter {
            if let limit = filter.limit {
                descriptor.fetchLimit = max(0, limit)
            }
            if filter.offset > 0 {
                descriptor.fetchOffset = filter.offset
            }
            return fetch(descriptor)
        }

        let remaining = Array(tokens.dropFirst())
        let kinds = needsKindFilter ? filter.kinds : nil
        return fetchFiltered(descriptor, offset: filter.offset, limit: filter.limit) { item in
            SearchEngine.matches(item, kinds: kinds) && SearchEngine.matches(item, tokens: remaining)
        }
    }

    /// Exact paging for filters that run in memory: scans the sorted SQL result in
    /// batches until `offset + limit` matches are found (or the rows run out).
    private func fetchFiltered(
        _ base: FetchDescriptor<ClipItem>,
        offset: Int,
        limit: Int?,
        where isMatch: (ClipItem) -> Bool
    ) -> [ClipItem] {
        guard let limit = limit else {
            let all: [ClipItem] = fetch(base).filter(isMatch)
            return ClipStore.page(all, offset: offset, limit: nil)
        }
        let needed = max(0, offset) + max(0, limit)
        if needed == 0 { return [] }
        let batchSize = max(200, needed)
        var matched: [ClipItem] = []
        var scanned = 0
        while matched.count < needed {
            var descriptor = base
            descriptor.fetchOffset = scanned
            descriptor.fetchLimit = batchSize
            let batch = fetch(descriptor)
            matched.append(contentsOf: batch.filter(isMatch))
            scanned += batch.count
            if batch.count < batchSize { break }
        }
        return ClipStore.page(matched, offset: offset, limit: limit)
    }

    /// Most recently used item (for "Copy latest").
    public func latestItem() -> ClipItem? {
        return fetchItems(ClipFilter(limit: 1)).first
    }

    public func item(withID id: UUID) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate<ClipItem> { $0.id == id })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    public func item(withContentHash hash: String) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate<ClipItem> { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    /// Total number of items in history.
    public func itemCount() -> Int {
        return (try? context.fetchCount(FetchDescriptor<ClipItem>())) ?? 0
    }

    // MARK: - Item mutations

    /// Bumps `lastUsedAt` to now (call after pasting/copying an item).
    public func markUsed(_ item: ClipItem) {
        item.lastUsedAt = Date()
        persist()
    }

    public func pin(_ item: ClipItem) {
        setPinned(true, for: item)
    }

    public func unpin(_ item: ClipItem) {
        setPinned(false, for: item)
    }

    public func togglePin(_ item: ClipItem) {
        setPinned(!item.isPinned, for: item)
    }

    public func setPinned(_ pinned: Bool, for item: ClipItem) {
        guard item.isPinned != pinned else { return }
        item.isPinned = pinned
        persist()
    }

    /// Sets a custom title (nil restores the derived title).
    public func setTitle(_ title: String?, for item: ClipItem) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmed, !trimmed.isEmpty {
            item.title = trimmed
        } else {
            item.title = ClipText.derivedTitle(from: item.plainText)
        }
        item.refreshSearchText()
        persist()
    }

    /// Stores OCR output ("" = processed, no text) and reindexes the item.
    public func setOCRText(_ text: String?, for item: ClipItem) {
        item.ocrText = text
        item.refreshSearchText()
        persist()
    }

    /// Adds (or replaces) a ClipSync-internal representation such as a thumbnail.
    public func setInternalRepresentation(_ data: Data, uti: String, for item: ClipItem) {
        guard ClipUTI.isInternal(uti) else { return }
        var reps = item.representations ?? []
        if let index = reps.firstIndex(where: { $0.uti == uti }) {
            let old = reps.remove(at: index)
            context.delete(old)
        }
        let model = makeRepresentation(uti: uti, data: data, sortIndex: 1_000 + reps.count)
        context.insert(model)
        reps.append(model)
        item.representations = reps
        persist()
    }

    public func delete(_ item: ClipItem) {
        delete([item])
    }

    /// Deletes items (and their representations); orphaned blob files are removed.
    public func delete(_ items: [ClipItem]) {
        guard !items.isEmpty else { return }
        var blobNames = Set<String>()
        for item in items {
            for rep in item.representations ?? [] {
                if let name = rep.fileName {
                    blobNames.insert(name)
                }
            }
            context.delete(item)
        }
        persist()
        removeOrphanedBlobs(blobNames)
    }

    /// Deletes history. With `keepPinned` (default) pinned and pinboard items survive.
    /// Returns the number of deleted items.
    @discardableResult
    public func clearHistory(keepPinned: Bool = true) -> Int {
        let all = fetch(FetchDescriptor<ClipItem>())
        let victims = keepPinned ? all.filter { !$0.isProtected } : all
        delete(victims)
        // Belt and braces: also remove every blob file (payloads, thumbnails, link
        // images) that no remaining representation references.
        removeUnreferencedBlobs()
        return victims.count
    }

    // MARK: - Retention & limits

    /// Deletes unprotected items whose `lastUsedAt` is older than the policy allows.
    /// Pinned items and pinboard items are never deleted. Returns the count deleted.
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy, now: Date = Date()) -> Int {
        guard let cutoff = policy.cutoffDate(from: now) else { return 0 }
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate<ClipItem> { $0.lastUsedAt < cutoff && $0.isPinned == false }
        )
        let victims = fetch(descriptor).filter { !$0.isProtected }
        delete(victims)
        return victims.count
    }

    /// Keeps at most `maxCount` items (protected items are never deleted; 0 = unlimited).
    /// Oldest `lastUsedAt` go first. Returns the count deleted.
    @discardableResult
    public func trimHistory(toMaxCount maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        let total = itemCount()
        guard total > maxCount else { return 0 }
        let excess = total - maxCount
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate<ClipItem> { $0.isPinned == false },
            sortBy: [SortDescriptor(\ClipItem.lastUsedAt, order: .forward)]
        )
        let victims = Array(fetch(descriptor).filter { !$0.isProtected }.prefix(excess))
        delete(victims)
        return victims.count
    }

    /// Applies `settings.retention` and `settings.maxHistoryCount`. Call at launch and
    /// periodically (e.g. hourly). Returns the count deleted.
    @discardableResult
    public func runMaintenance(now: Date = Date()) -> Int {
        let policy = settings?.retention ?? AppSettings.defaultRetention
        var removed = applyRetention(policy, now: now)
        if let maxCount = settings?.maxHistoryCount {
            removed += trimHistory(toMaxCount: maxCount)
        }
        removed += removeUnreferencedBlobs()
        return removed
    }

    /// Deletes blob files that no representation references. Returns files removed.
    @discardableResult
    public func removeUnreferencedBlobs() -> Int {
        let referenced = Set(fetch(FetchDescriptor<ClipRepresentation>()).compactMap { $0.fileName })
        var removed = 0
        for name in blobStore.allFileNames() where !referenced.contains(name) {
            blobStore.delete(name)
            removed += 1
        }
        return removed
    }

    private func trimHistoryIfNeeded() {
        guard let maxCount = settings?.maxHistoryCount, maxCount > 0 else { return }
        trimHistory(toMaxCount: maxCount)
    }

    private func removeOrphanedBlobs(_ names: Set<String>) {
        for name in names {
            let optionalName: String? = name
            let descriptor = FetchDescriptor<ClipRepresentation>(
                predicate: #Predicate<ClipRepresentation> { $0.fileName == optionalName }
            )
            let references = (try? context.fetchCount(descriptor)) ?? 1
            if references == 0 {
                blobStore.delete(name)
            }
        }
    }

    // MARK: - Pinboards

    /// All pinboards in display order.
    public func pinboards() -> [Pinboard] {
        let descriptor = FetchDescriptor<Pinboard>(
            sortBy: [
                SortDescriptor(\Pinboard.sortOrder, order: .forward),
                SortDescriptor(\Pinboard.createdAt, order: .forward)
            ]
        )
        return fetch(descriptor)
    }

    public func pinboard(withID id: UUID) -> Pinboard? {
        var descriptor = FetchDescriptor<Pinboard>(predicate: #Predicate<Pinboard> { $0.id == id })
        descriptor.fetchLimit = 1
        return fetch(descriptor).first
    }

    /// Creates a pinboard at the end of the list.
    @discardableResult
    public func createPinboard(name: String, colorHex: String = ClipConstants.defaultPinboardColorHex) -> Pinboard {
        let nextOrder = (pinboards().map { $0.sortOrder }.max() ?? -1) + 1
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let board = Pinboard(
            name: trimmed.isEmpty ? "Pinboard" : trimmed,
            colorHex: ColorParser.normalizedHex(from: colorHex) ?? ClipConstants.defaultPinboardColorHex,
            sortOrder: nextOrder
        )
        context.insert(board)
        persist()
        return board
    }

    public func renamePinboard(_ board: Pinboard, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        board.name = trimmed
        persist()
    }

    /// Sets the color ("#RRGGBB"); invalid strings are ignored.
    public func setColor(_ colorHex: String, for board: Pinboard) {
        guard let hex = ColorParser.normalizedHex(from: colorHex) else { return }
        board.colorHex = hex
        persist()
    }

    /// Deletes the pinboard. Its items stay in history (no longer protected by it).
    public func deletePinboard(_ board: Pinboard) {
        context.delete(board)
        persist()
        normalizePinboardOrder()
    }

    /// Persists the given order (index = new sortOrder). Boards not listed keep their
    /// relative order after the listed ones.
    public func reorderPinboards(_ ordered: [Pinboard]) {
        var seen = Set<UUID>()
        var ordering: [Pinboard] = []
        for board in ordered where seen.insert(board.id).inserted {
            ordering.append(board)
        }
        for board in pinboards() where seen.insert(board.id).inserted {
            ordering.append(board)
        }
        for (index, board) in ordering.enumerated() where board.sortOrder != index {
            board.sortOrder = index
        }
        persist()
    }

    /// SwiftUI `List.onMove` semantics over `pinboards()`.
    public func movePinboards(fromOffsets source: IndexSet, toOffset destination: Int) {
        var boards = pinboards()
        let offsets = source.sorted().filter { $0 >= 0 && $0 < boards.count }
        guard !offsets.isEmpty else { return }
        let moving = offsets.map { boards[$0] }
        let movedBeforeDestination = offsets.filter { $0 < destination }.count
        for index in offsets.reversed() {
            boards.remove(at: index)
        }
        let insertAt = min(max(destination - movedBeforeDestination, 0), boards.count)
        boards.insert(contentsOf: moving, at: insertAt)
        reorderPinboards(boards)
    }

    /// Moves one pinboard so it ends up at index `to` (remove-then-insert semantics).
    public func movePinboard(from: Int, to: Int) {
        var boards = pinboards()
        guard from >= 0, from < boards.count else { return }
        let board = boards.remove(at: from)
        let target = min(max(to, 0), boards.count)
        boards.insert(board, at: target)
        reorderPinboards(boards)
    }

    /// Adds an item to a pinboard (no-op if already there).
    public func add(_ item: ClipItem, to board: Pinboard) {
        var list = board.items ?? []
        if list.contains(where: { $0.id == item.id }) { return }
        list.append(item)
        board.items = list
        persist()
    }

    public func remove(_ item: ClipItem, from board: Pinboard) {
        let list = board.items ?? []
        guard list.contains(where: { $0.id == item.id }) else { return }
        board.items = list.filter { $0.id != item.id }
        persist()
    }

    /// Items of a pinboard, newest `lastUsedAt` first.
    public func items(in board: Pinboard) -> [ClipItem] {
        return (board.items ?? []).sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func normalizePinboardOrder() {
        reorderPinboards(pinboards())
    }

    // MARK: - Media enrichment

    /// Runs OCR / thumbnail / link-metadata for an item using `media`.
    /// Safe to call repeatedly; does nothing with the default no-op services.
    /// Link metadata is fetched only when `settings?.linkPreviewsEnabled == true`
    /// (OCR and thumbnails are on-device and always run).
    public func enrich(_ item: ClipItem) async {
        let services = media
        switch item.kind {
        case .image:
            guard let rep = item.pasteableRepresentations.first(where: { ClipUTI.isImage($0.uti) }),
                  let imageData = data(for: rep) else { return }
            let uti = rep.uti
            if item.ocrText == nil {
                let text = await services.textRecognizer.recognizeText(in: imageData)
                guard ClipStore.isAlive(item) else { return }
                if let text = text {
                    setOCRText(text, for: item)
                }
            }
            if item.representation(forUTI: ClipUTI.thumbnail) == nil {
                let png = await services.thumbnails.thumbnailPNG(for: imageData, uti: uti, maxPixelSize: 512)
                guard ClipStore.isAlive(item) else { return }
                if let png = png {
                    setInternalRepresentation(png, uti: ClipUTI.thumbnail, for: item)
                }
            }
        case .pdf:
            guard item.representation(forUTI: ClipUTI.thumbnail) == nil,
                  let pdfData = data(for: item, uti: ClipUTI.pdf) else { return }
            let png = await services.thumbnails.thumbnailPNG(for: pdfData, uti: ClipUTI.pdf, maxPixelSize: 512)
            guard ClipStore.isAlive(item) else { return }
            if let png = png {
                setInternalRepresentation(png, uti: ClipUTI.thumbnail, for: item)
            }
        case .link:
            // Network gate: link previews contact the linked website, so they run only
            // when the user turned them on (default off; no settings = off).
            guard settings?.linkPreviewsEnabled == true else { return }
            guard item.representation(forUTI: ClipUTI.linkIcon) == nil else { return }
            let urlString = (item.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: urlString) else { return }
            linkFetchAttempts &+= 1
            let metadata = await services.linkMetadata.fetchMetadata(for: url)
            guard ClipStore.isAlive(item), let meta = metadata else { return }
            if let newTitle = meta.title, !newTitle.isEmpty,
               item.title == nil || item.title == urlString {
                setTitle(newTitle, for: item)
            }
            if let icon = meta.iconData {
                setInternalRepresentation(icon, uti: ClipUTI.linkIcon, for: item)
            }
            if let image = meta.imageData {
                setInternalRepresentation(image, uti: ClipUTI.linkPreviewImage, for: item)
            }
        case .text, .richText, .file, .color:
            break
        }
    }

    private static func isAlive(_ item: ClipItem) -> Bool {
        return item.modelContext != nil && !item.isDeleted
    }

    // MARK: - Plumbing

    /// Saves pending changes (normally automatic after each mutation).
    public func save() {
        persist()
    }

    private func persist() {
        do {
            if context.hasChanges {
                try context.save()
            }
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
        revision &+= 1
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            lastSaveError = "Fetch failed: \(error.localizedDescription)"
            return []
        }
    }

    private static func page(_ items: [ClipItem], offset: Int, limit: Int?) -> [ClipItem] {
        let start = min(max(offset, 0), items.count)
        var end = items.count
        if let limit = limit {
            end = min(items.count, start + max(0, limit))
        }
        return Array(items[start..<end])
    }
}
