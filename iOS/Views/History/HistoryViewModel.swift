import Foundation
import SwiftUI
import ClipCore

/// Filter chips. Some chips cover two kinds (Text = plain + rich, Files = files + PDFs).
enum KindFilter: String, CaseIterable, Identifiable, Hashable {
    case all, text, links, images, files, colors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .files: return "Files"
        case .colors: return "Colors"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.stack"
        case .text: return ClipKind.text.systemImageName
        case .links: return ClipKind.link.systemImageName
        case .images: return ClipKind.image.systemImageName
        case .files: return ClipKind.file.systemImageName
        case .colors: return ClipKind.color.systemImageName
        }
    }

    var kinds: [ClipKind] {
        switch self {
        case .all: return []
        case .text: return [.text, .richText]
        case .links: return [.link]
        case .images: return [.image]
        case .files: return [.file, .pdf]
        case .colors: return [.color]
        }
    }
}

/// Which slice of history a screen shows.
enum HistoryScope: Hashable {
    case all
    case pinned
    case pinboard(UUID)
}

enum HistoryLayout: String {
    case list, grid
}

struct HistoryQueryKey: Equatable {
    var search: String
    var kind: KindFilter
}

/// Paged, imperative fetch through `ClipStore.fetchItems(_:)` (newest `lastUsedAt` first).
/// Refreshed by the view on `store.revision` and on external-change notifications.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var hasMore = false
    @Published var searchText = ""
    @Published var kindFilter: KindFilter

    let scope: HistoryScope
    private let store: ClipStore
    private let pageSize = 120

    init(store: ClipStore, scope: HistoryScope, kindFilter: KindFilter = .all) {
        self.store = store
        self.scope = scope
        self.kindFilter = kindFilter
    }

    var isSearching: Bool {
        return !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Re-fetches keeping the number of rows already loaded (so scroll position survives).
    func reload() {
        load(count: max(pageSize, items.count))
    }

    /// New query: back to the first page.
    func resetAndReload() {
        load(count: pageSize)
    }

    /// Call from a row's onAppear; loads the next page when the last row shows up.
    func loadMoreIfNeeded(currentItem item: ClipItem) {
        guard hasMore, let last = items.last, last.id == item.id else { return }
        let kinds = kindFilter.kinds
        if kinds.count <= 1 && !isMultiTokenSearch {
            appendPage(kind: kinds.first)
        } else {
            load(count: items.count + pageSize)
        }
    }

    // MARK: - Private

    private var isMultiTokenSearch: Bool {
        return SearchEngine.tokens(from: searchText).count > 1
    }

    private func makeFilter(kind: ClipKind?, limit: Int, offset: Int) -> ClipFilter {
        var pinboardID: UUID? = nil
        var pinnedOnly = false
        switch scope {
        case .all:
            break
        case .pinned:
            pinnedOnly = true
        case .pinboard(let id):
            pinboardID = id
        }
        return ClipFilter(
            kind: kind,
            pinboardID: pinboardID,
            searchText: searchText,
            pinnedOnly: pinnedOnly,
            limit: limit,
            offset: offset
        )
    }

    /// Fetches the first `count` matches (+1 to know whether more exist).
    private func load(count: Int) {
        let kinds = kindFilter.kinds
        var results: [ClipItem]
        if kinds.count <= 1 {
            results = store.fetchItems(makeFilter(kind: kinds.first, limit: count + 1, offset: 0))
        } else {
            // ClipFilter takes one kind: fetch each and merge by the store's sort key.
            var merged: [ClipItem] = []
            for kind in kinds {
                merged.append(contentsOf: store.fetchItems(makeFilter(kind: kind, limit: count + 1, offset: 0)))
            }
            merged.sort { $0.lastUsedAt > $1.lastUsedAt }
            results = Array(merged.prefix(count + 1))
        }
        hasMore = results.count > count
        if hasMore {
            results.removeLast(results.count - count)
        }
        items = results
    }

    /// Single-kind fast path: fetch only the next page with an offset.
    private func appendPage(kind: ClipKind?) {
        let page = store.fetchItems(makeFilter(kind: kind, limit: pageSize + 1, offset: items.count))
        hasMore = page.count > pageSize
        let existing = Set(items.map { $0.id })
        let fresh = page.prefix(pageSize).filter { !existing.contains($0.id) }
        items.append(contentsOf: fresh)
    }
}
