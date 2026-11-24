import Foundation
import SwiftData

/// A user-curated, ordered collection of items. Items in a pinboard are never
/// removed by retention cleanup or "clear history (keep pinned)".
@Model
public final class Pinboard {
    public var id: UUID = UUID()
    public var name: String = ""
    /// "#RRGGBB" (see `ClipConstants.pinboardPalette`).
    public var colorHex: String = "#3B82F6"
    /// Ascending display order. Maintained by ClipStore reorder APIs.
    public var sortOrder: Int = 0
    public var createdAt: Date = Date()
    /// Inverse of `ClipItem.pinboards` (declared on ClipItem). Unordered — use
    /// `ClipStore.items(in:)` for a sorted list.
    public var items: [ClipItem]? = []

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#3B82F6",
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

extension Pinboard {
    /// Number of items in the pinboard.
    public var itemCount: Int {
        return (items ?? []).count
    }
}

/// The SwiftData schema shared by every target.
public enum ClipSchema {
    public static var models: [any PersistentModel.Type] {
        return [ClipItem.self, ClipRepresentation.self, Pinboard.self]
    }

    public static var schema: Schema {
        return Schema(models)
    }
}
