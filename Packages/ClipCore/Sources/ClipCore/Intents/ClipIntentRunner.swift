import Foundation

// Owned by the extensions engineer.
//
// Store-side logic of every ClipSync App Intent, factored out of the AppIntent structs so
// that (1) it is unit-testable against an in-memory `ClipStore`, and (2) app targets can
// declare thin wrapper intents that call it if Shortcuts does not discover the intents
// compiled into this static library (see docs/API.md §7).

/// Errors shown by Shortcuts when an intent fails.
public enum ClipIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case emptyText
    case emptyClipboard
    /// The clipboard carried a concealed / transient / password-manager marker.
    case sensitiveContent
    case rejected(IngestRejection)
    case noItems
    case itemNotFound
    case pasteboardWriteFailed
    /// App Lock is on and ClipSync is locked: reading / copying history is refused
    /// (saving new items still works).
    case locked

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText:
            return "There is no text to save."
        case .emptyClipboard:
            return "The clipboard is empty or holds nothing ClipSync can save."
        case .sensitiveContent:
            return "The clipboard is marked as sensitive (for example a password), so ClipSync did not save it."
        case .rejected(let reason):
            switch reason {
            case .ignoredApp:
                return "ClipSync ignores content from this app."
            case .markerType:
                return "The content is marked as sensitive, so ClipSync did not save it."
            case .empty:
                return "There is nothing to save."
            case .tooLarge:
                return "The content is too large to save."
            }
        case .noItems:
            return "Your ClipSync history is empty."
        case .itemNotFound:
            return "That clip is no longer in your ClipSync history."
        case .pasteboardWriteFailed:
            return "ClipSync could not write to the clipboard."
        case .locked:
            return "ClipSync is locked. Unlock it in the app, then try again."
        }
    }
}

@MainActor
public enum ClipIntentRunner {
    /// Source name stamped on items saved through Shortcuts.
    public static let sourceAppName = "Shortcuts"
    public static let defaultSearchLimit = 10
    public static let maxSearchLimit = 100

    /// Result of a save / copy intent.
    public struct Reply: Sendable, Equatable {
        /// The item's text (plain text, else OCR text, else its display title).
        public let value: String
        /// Short sentence for Siri / the Shortcuts dialog.
        public let dialog: String
        public let itemID: UUID
        /// True when the content was already in history and was only bumped to the top.
        public let wasDuplicate: Bool
    }

    /// Result of a search intent.
    public struct SearchReply: Sendable {
        public let entities: [ClipEntity]
        public let texts: [String]
        public let dialog: String
    }

    // MARK: App Lock

    /// Throws `.locked` when App Lock is on and the timeout has passed (or ClipSync was
    /// locked). Called by every intent / entity query that READS history. Saving intents
    /// do not call it: saving new items is allowed while locked (write-only).
    public static func requireUnlocked() throws {
        try requireUnlocked(lock: AppLockController.shared)
    }

    public static func requireUnlocked(lock: AppLockController) throws {
        if lock.checkTimeout() {
            throw ClipIntentError.locked
        }
    }

    // MARK: Save

    /// "Save Text to ClipSync" (the reliable Shortcuts path: Get Clipboard → Save Text).
    public static func saveText(_ text: String, store: ClipStore) throws -> Reply {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipIntentError.emptyText
        }
        let draft = ClipDraft.text(text, sourceAppName: sourceAppName)
        return try save(draft, store: store)
    }

    /// "Save Clipboard to ClipSync" reading the real system pasteboard.
    public static func saveClipboard(store: ClipStore) throws -> Reply {
        return try saveClipboard(store: store, reader: { try SystemPasteboard.readDraft() })
    }

    /// Same with an injectable pasteboard reader (tests).
    public static func saveClipboard(store: ClipStore, reader: @MainActor () throws -> ClipDraft) throws -> Reply {
        var draft = try reader()
        if draft.sourceAppName == nil {
            draft.sourceAppName = sourceAppName
        }
        return try save(draft, store: store)
    }

    /// Ingests a draft and schedules best-effort enrichment (thumbnail / OCR / link title).
    public static func save(_ draft: ClipDraft, store: ClipStore) throws -> Reply {
        let result = store.ingestDetailed(draft)
        switch result {
        case .inserted(let item):
            scheduleEnrichment(item, store: store)
            return Reply(value: text(for: item), dialog: "Saved to ClipSync.", itemID: item.id, wasDuplicate: false)
        case .bumped(let item):
            return Reply(value: text(for: item), dialog: "Already in ClipSync, moved to the top.", itemID: item.id, wasDuplicate: true)
        case .rejected(let reason):
            if reason == .markerType {
                throw ClipIntentError.sensitiveContent
            }
            throw ClipIntentError.rejected(reason)
        }
    }

    // MARK: Search

    /// Matching items, newest first. An empty query returns the most recent items.
    public static func search(_ query: String, limit: Int, store: ClipStore) -> SearchReply {
        let clamped = min(max(limit, 1), maxSearchLimit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = store.fetchItems(ClipFilter(searchText: trimmed, limit: clamped))
        let dialog: String
        if items.isEmpty {
            dialog = trimmed.isEmpty ? "Your ClipSync history is empty." : "No clips match \u{201C}\(trimmed)\u{201D}."
        } else if items.count == 1 {
            dialog = "Found 1 clip: \(items[0].displayTitle)"
        } else {
            dialog = "Found \(items.count) clips."
        }
        return SearchReply(
            entities: items.map { entity(for: $0) },
            texts: items.map { text(for: $0) },
            dialog: dialog
        )
    }

    // MARK: Copy

    /// Copies the newest item to the system pasteboard and returns its text.
    public static func copyLatest(store: ClipStore) throws -> Reply {
        return try copyLatest(store: store, writer: { reps, text in
            SystemPasteboard.write(reps, plainText: text)
        })
    }

    /// Same with an injectable pasteboard writer (tests). The writer returns success.
    public static func copyLatest(
        store: ClipStore,
        writer: @MainActor ([ClipDraft.Representation], String?) -> Bool
    ) throws -> Reply {
        guard let item = store.latestItem() else { throw ClipIntentError.noItems }
        return try copy(item, store: store, writer: writer)
    }

    /// Copies a specific item (by entity id) to the system pasteboard.
    public static func copyItem(id: UUID, store: ClipStore) throws -> Reply {
        return try copyItem(id: id, store: store, writer: { reps, text in
            SystemPasteboard.write(reps, plainText: text)
        })
    }

    public static func copyItem(
        id: UUID,
        store: ClipStore,
        writer: @MainActor ([ClipDraft.Representation], String?) -> Bool
    ) throws -> Reply {
        guard let item = store.item(withID: id) else { throw ClipIntentError.itemNotFound }
        return try copy(item, store: store, writer: writer)
    }

    private static func copy(
        _ item: ClipItem,
        store: ClipStore,
        writer: @MainActor ([ClipDraft.Representation], String?) -> Bool
    ) throws -> Reply {
        let payload = store.pasteboardPayload(for: item)
        guard writer(payload, item.plainText) else { throw ClipIntentError.pasteboardWriteFailed }
        store.markUsed(item)
        return Reply(value: text(for: item), dialog: "Copied \u{201C}\(item.displayTitle)\u{201D}.", itemID: item.id, wasDuplicate: false)
    }

    // MARK: Entities

    public static func entity(for item: ClipItem) -> ClipEntity {
        return ClipEntity(
            id: item.id,
            title: item.displayTitle,
            text: text(for: item),
            kindName: item.kind.displayName,
            lastUsedAt: item.lastUsedAt,
            isPinned: item.isPinned
        )
    }

    /// Entities for the given ids, in the given order (missing ids are dropped).
    public static func entities(for identifiers: [UUID], store: ClipStore) -> [ClipEntity] {
        var result: [ClipEntity] = []
        for id in identifiers {
            if let item = store.item(withID: id) {
                result.append(entity(for: item))
            }
        }
        return result
    }

    public static func suggestedEntities(store: ClipStore, limit: Int = 20) -> [ClipEntity] {
        return store.fetchItems(ClipFilter(limit: max(1, limit))).map { entity(for: $0) }
    }

    // MARK: Helpers

    /// Best text for an item: plain text, else OCR text, else the display title.
    public static func text(for item: ClipItem) -> String {
        if let plain = item.plainText, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plain
        }
        if let ocr = item.ocrText, !ocr.isEmpty {
            return ocr
        }
        return item.displayTitle
    }

    /// Fire-and-forget `store.enrich` (no-op unless the app installed `MediaServices.live()`).
    /// The intent does not wait for it; if the process is suspended first, the app can
    /// enrich the item on its next launch.
    public static func scheduleEnrichment(_ item: ClipItem, store: ClipStore) {
        Task { @MainActor in
            await store.enrich(item)
        }
    }
}
