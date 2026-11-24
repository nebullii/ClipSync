import SwiftUI
import ClipCore

/// History (or a pinned / pinboard slice of it): search, kind chips, list ⇄ grid, paging,
/// save bar, detail sheet. Lives inside a NavigationStack provided by the caller.
struct HistoryScreen: View {
    let title: String
    let board: Pinboard?
    let showsKindFilter: Bool
    let showsSaveBar: Bool
    let showsCloudBanner: Bool

    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var viewModel: HistoryViewModel
    @AppStorage(LaunchOptions.historyLayoutKey) private var layoutRaw = "auto"
    @State private var detailItem: ClipItem? = nil

    init(
        store: ClipStore,
        scope: HistoryScope,
        title: String,
        board: Pinboard? = nil,
        initialKind: KindFilter = .all,
        showsKindFilter: Bool = true,
        showsSaveBar: Bool = true,
        showsCloudBanner: Bool = false
    ) {
        self.title = title
        self.board = board
        self.showsKindFilter = showsKindFilter
        self.showsSaveBar = showsSaveBar
        self.showsCloudBanner = showsCloudBanner
        _viewModel = StateObject(wrappedValue: HistoryViewModel(store: store, scope: scope, kindFilter: initialKind))
    }

    private var layout: HistoryLayout {
        if let explicit = HistoryLayout(rawValue: layoutRaw) {
            return explicit
        }
        return horizontalSizeClass == .regular ? .grid : .list
    }

    var body: some View {
        HistoryContent(
            viewModel: viewModel,
            layout: layout,
            board: board,
            onShowDetail: { item in detailItem = item }
        )
        .navigationTitle(title)
        .searchable(text: $viewModel.searchText, prompt: Text("Search clips"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LayoutToggleButton(layout: layout) { newLayout in
                    layoutRaw = newLayout.rawValue
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HistoryHeader(
                kindFilter: $viewModel.kindFilter,
                showsKindFilter: showsKindFilter,
                showsCloudBanner: showsCloudBanner
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsSaveBar {
                SaveClipboardBar()
            }
        }
        .task(id: HistoryQueryKey(search: viewModel.searchText, kind: viewModel.kindFilter)) {
            if viewModel.isSearching {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
            }
            viewModel.resetAndReload()
        }
        .onReceive(model.store.$revision) { _ in
            viewModel.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipSyncIOSExternalChange)) { _ in
            viewModel.reload()
        }
        .sheet(item: $detailItem) { item in
            NavigationStack {
                ClipDetailView(item: item)
            }
            .environmentObject(model)
            .environmentObject(model.store)
            .environmentObject(model.settings)
            .environmentObject(model.boards)
        }
    }
}

/// Banner + chips pinned under the navigation bar.
private struct HistoryHeader: View {
    @Binding var kindFilter: KindFilter
    let showsKindFilter: Bool
    let showsCloudBanner: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if showsCloudBanner {
                CloudBanner(cloud: model.cloud)
            }
            if showsKindFilter {
                KindFilterBar(selection: $kindFilter)
            }
        }
        .background(.bar)
    }
}

private struct LayoutToggleButton: View {
    let layout: HistoryLayout
    let onChange: (HistoryLayout) -> Void

    var body: some View {
        Button {
            onChange(layout == .list ? .grid : .list)
        } label: {
            Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
        }
        .accessibilityLabel(Text((layout == .list ? "Show as grid" : "Show as list") as String))
        .accessibilityIdentifier("history.layoutToggle")
    }
}

/// Empty state, list or grid.
private struct HistoryContent: View {
    @ObservedObject var viewModel: HistoryViewModel
    let layout: HistoryLayout
    let board: Pinboard?
    let onShowDetail: (ClipItem) -> Void

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if viewModel.items.isEmpty {
                HistoryEmptyView(
                    isSearching: viewModel.isSearching,
                    searchText: viewModel.searchText,
                    scope: viewModel.scope
                )
            } else if layout == .grid {
                HistoryGridView(
                    items: viewModel.items,
                    board: board,
                    onItemAppear: { viewModel.loadMoreIfNeeded(currentItem: $0) },
                    onShowDetail: onShowDetail
                )
            } else {
                HistoryListView(
                    items: viewModel.items,
                    board: board,
                    onItemAppear: { viewModel.loadMoreIfNeeded(currentItem: $0) },
                    onShowDetail: onShowDetail
                )
            }
        }
        .refreshable {
            await MainActor.run {
                model.refreshFromStore()
            }
        }
    }
}

private struct HistoryListView: View {
    let items: [ClipItem]
    let board: Pinboard?
    let onItemAppear: (ClipItem) -> Void
    let onShowDetail: (ClipItem) -> Void

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ClipListRow(item: item, index: index, board: board, onShowDetail: onShowDetail)
                    .onAppear { onItemAppear(item) }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("history.list")
    }
}

private struct HistoryGridView: View {
    let items: [ClipItem]
    let board: Pinboard?
    let onItemAppear: (ClipItem) -> Void
    let onShowDetail: (ClipItem) -> Void

    @ScaledMetric(relativeTo: .body) private var minCardWidth: CGFloat = 160

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: min(minCardWidth, 320)), spacing: 12)], spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ClipCardCell(item: item, index: index, board: board, onShowDetail: onShowDetail)
                        .onAppear { onItemAppear(item) }
                }
            }
            .padding(16)
        }
        .background(Theme.groupedBackground)
        .accessibilityIdentifier("history.grid")
    }
}

private struct HistoryEmptyView: View {
    let isSearching: Bool
    let searchText: String
    let scope: HistoryScope

    var body: some View {
        if isSearching {
            ContentUnavailableView.search(text: searchText)
        } else {
            switch scope {
            case .all:
                ContentUnavailableView {
                    Label("No clips yet", systemImage: "doc.on.clipboard")
                } description: {
                    Text("Copy something, then tap Paste below to save it. With iCloud sync on, what you copy on your Mac shows up here too.")
                }
            case .pinned:
                ContentUnavailableView {
                    Label("Nothing pinned", systemImage: "pin")
                } description: {
                    Text("Swipe right on a clip to pin it. Pinned clips are never cleaned up.")
                }
            case .pinboard:
                ContentUnavailableView {
                    Label("Empty pinboard", systemImage: "pin.square")
                } description: {
                    Text("Add clips with the + button, or from a clip's menu: Add to Pinboard.")
                }
            }
        }
    }
}
