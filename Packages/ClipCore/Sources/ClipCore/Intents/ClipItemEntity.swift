import Foundation
import AppIntents
import CoreTransferable

// Owned by the extensions engineer.

/// A ClipSync history item as seen by Shortcuts / Siri / Spotlight.
/// A value snapshot (never holds a SwiftData model), so it is safely Sendable.
public struct ClipEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Clip"
    public static var defaultQuery = ClipEntityQuery()

    public var id: UUID

    @Property(title: "Title")
    public var title: String

    @Property(title: "Text")
    public var text: String

    @Property(title: "Kind")
    public var kindName: String

    @Property(title: "Last Used")
    public var lastUsedAt: Date

    @Property(title: "Pinned")
    public var isPinned: Bool

    public var displayRepresentation: DisplayRepresentation {
        return DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(kindName)"
        )
    }

    public init(id: UUID, title: String, text: String, kindName: String, lastUsedAt: Date, isPinned: Bool) {
        self.id = id
        self.title = title
        self.text = text
        self.kindName = kindName
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
    }
}

/// Lets Shortcuts coerce a clip to text (e.g. "Search Clips" → "Copy to Clipboard").
extension ClipEntity: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { (entity: ClipEntity) in entity.text })
    }
}

/// Planned name in docs/API.md / IntentsContract.swift.
public typealias ClipItemEntity = ClipEntity

/// Resolves clips by id, by free text (Shortcuts' search field) and suggests recent ones.
/// Store work hops to the main actor (`ClipStore` is `@MainActor`).
/// Every query throws `ClipIntentError.locked` while App Lock has ClipSync locked.
public struct ClipEntityQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [UUID]) async throws -> [ClipEntity] {
        return try await MainActor.run {
            try ClipIntentRunner.requireUnlocked()
            return ClipIntentRunner.entities(for: identifiers, store: ClipStore.shared)
        }
    }

    public func entities(matching string: String) async throws -> [ClipEntity] {
        return try await MainActor.run {
            try ClipIntentRunner.requireUnlocked()
            return ClipIntentRunner.search(string, limit: 50, store: ClipStore.shared).entities
        }
    }

    public func suggestedEntities() async throws -> [ClipEntity] {
        return try await MainActor.run {
            try ClipIntentRunner.requireUnlocked()
            return ClipIntentRunner.suggestedEntities(store: ClipStore.shared, limit: 20)
        }
    }
}
