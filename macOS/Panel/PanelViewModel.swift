// Owned by the Mac panel UI engineer.
//
// All panel logic that is not view layout lives here: paging through the store,
// filter/scope/search state, selection movement, number-key mapping, pinboard
// management and the actions behind keyboard shortcuts and context menus.

import AppKit
import Combine
import ClipCore

// MARK: - Small value types used by the views

/// One card in the strip. `id` is captured at fetch time so SwiftUI identity never
/// has to touch a model object that may have been deleted in the meantime.
struct PanelCardRow: Identifiable {
    let id: UUID
    let index: Int
    let item: ClipItem
}

/// One pinboard tab. Name and color are captured at refresh time for the same reason.
struct PanelPinboardRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let colorHex: String

    static func == (lhs: PanelPinboardRow, rhs: PanelPinboardRow) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name && lhs.colorHex == rhs.colorHex
    }
}

/// Which list the strip shows.
enum PanelScope: Equatable {
    case history
    case pinboard(UUID)
}

/// The kind filter chips. Each chip maps to a SET of kinds (`ClipFilter.kinds`):
/// Text = text + rich text, Files = files + PDFs.
enum PanelKindFilter: String, CaseIterable, Identifiable {
    case all, text, links, images, files, colors

    var id: String { return rawValue }

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

    /// Kinds shown by this chip (nil = every kind).
    var kinds: Set<ClipKind>? {
        switch self {
        case .all: return nil
        case .text: return [.text, .richText]
        case .links: return [.link]
        case .images: return [.image]
        case .files: return [.file, .pdf]
        case .colors: return [.color]
        }
    }

    var systemImageName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return ClipKind.text.systemImageName
        case .links: return ClipKind.link.systemImageName
        case .images: return ClipKind.image.systemImageName
        case .files: return ClipKind.file.systemImageName
        case .colors: return ClipKind.color.systemImageName
        }
    }
}

/// The inline text editor shown in the top bar (used instead of sheets/alerts, which
/// would take key status away from the non-activating panel and close it).
enum PanelInlineEditor: Equatable {
    /// Create a pinboard; optionally add this item to it afterwards.
    case newPinboard(addingItemID: UUID?)
    case renamePinboard(UUID)
    case renameItem(UUID)

    var prompt: String {
        switch self {
        case .newPinboard: return "New pinboard"
        case .renamePinboard: return "Rename pinboard"
        case .renameItem: return "Rename item"
        }
    }

    var placeholder: String {
        switch self {
        case .newPinboard, .renamePinboard: return "Pinboard name"
        case .renameItem: return "Title (empty = automatic)"
        }
    }

    var systemImageName: String {
        switch self {
        case .newPinboard: return "plus.rectangle.on.rectangle"
        case .renamePinboard, .renameItem: return "pencil"
        }
    }
}

enum PanelEmptyState: Equatable {
    case noHistory
    case noResults(query: String)
    case noItemsOfKind(String)
    case emptyPinboard(String)
}

/// Weak references to the AppKit text fields hosted in SwiftUI, so the panel
/// controller can move keyboard focus synchronously (SwiftUI focus is async).
@MainActor
final class PanelFocusBridge {
    weak var searchField: NSSearchField?
    weak var editorField: NSTextField?

    /// Makes the search field first responder with the caret at the end (no select-all,
    /// so a forwarded keystroke appends instead of replacing the query).
    @discardableResult
    func focusSearchField() -> Bool {
        guard let field = searchField, let window = field.window else { return false }
        if let editor = field.currentEditor(), window.firstResponder === editor {
            return true
        }
        guard window.makeFirstResponder(field) else { return false }
        if let editor = field.currentEditor() {
            let length = (field.stringValue as NSString).length
            editor.selectedRange = NSRange(location: length, length: 0)
        }
        return true
    }

    /// True while the search field's editor is first responder and has a non-empty selection.
    var searchFieldHasSelection: Bool {
        guard let field = searchField, let window = field.window,
              let editor = field.currentEditor(), window.firstResponder === editor else { return false }
        return editor.selectedRange.length > 0
    }
}

// MARK: - View model

@MainActor
final class PanelViewModel: ObservableObject {
    static let pageSize = 60
    static let loadMoreThreshold = 15
    static let shortcutCount = 9
    static let searchDebounceMilliseconds = 120

    let environment: AppEnvironment
    let focusBridge = PanelFocusBridge()
    /// Set by PanelController; used to hide after copy / settings.
    weak var presenter: PanelPresenting?

    @Published private(set) var rows: [PanelCardRow] = []
    @Published private(set) var pinboardRows: [PanelPinboardRow] = []
    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var scope: PanelScope = .history
    @Published private(set) var kindFilter: PanelKindFilter = .all
    /// Bound to the search field; applied to the store after a short debounce.
    @Published var searchText: String = ""
    @Published private(set) var inlineEditor: PanelInlineEditor?
    @Published var editorText: String = ""
    /// Incremented whenever the strip should scroll the selection into view.
    @Published private(set) var scrollRequest: Int = 0
    /// "Now" used for relative times; refreshed on show so cards don't tick while open.
    @Published private(set) var referenceDate = Date()
    @Published private(set) var historyIsEmpty = false

    private(set) var hasMore = false
    private(set) var selectedID: UUID?
    /// Called after the selection changes (PanelController refreshes Quick Look).
    var onSelectionChange: (() -> Void)?

    private var appliedSearch = ""
    private var isDirty = true
    private var isPanelVisible = false
    private var isLoadingMore = false
    private var refreshScheduled = false
    private var idleRefreshScheduled = false
    private var cancellables = Set<AnyCancellable>()

    /// In-process drag state (card → pinboard tab, tab → tab reorder).
    private var draggingItemID: UUID?
    private var draggingPinboardID: UUID?

    init(environment: AppEnvironment) {
        self.environment = environment

        environment.store.$revision
            .dropFirst()
            .sink { [weak self] _ in
                self?.storeDidChange()
            }
            .store(in: &cancellables)

        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(Self.searchDebounceMilliseconds), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                self?.applySearch(text)
            }
            .store(in: &cancellables)

        // Warm the first page shortly after launch so the first show() is instant too.
        scheduleIdleRefresh()
    }

    // MARK: Derived state

    var store: ClipStore { return environment.store }

    var items: [ClipItem] { return rows.map { $0.item } }

    var selectedItem: ClipItem? {
        guard rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex].item
    }

    var currentPinboardID: UUID? {
        if case .pinboard(let id) = scope { return id }
        return nil
    }

    var isSearchEmpty: Bool { return searchText.isEmpty }

    var emptyState: PanelEmptyState {
        let query = appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return .noResults(query: query) }
        if let boardID = currentPinboardID {
            let name = pinboardRows.first(where: { $0.id == boardID })?.name ?? "Pinboard"
            if kindFilter == .all { return .emptyPinboard(name) }
            return .noItemsOfKind(kindFilter.title)
        }
        if kindFilter != .all { return .noItemsOfKind(kindFilter.title) }
        return .noHistory
    }

    // MARK: Panel lifecycle

    /// Called by PanelController right before the panel appears. Cheap: at most one
    /// limited fetch (usually none — changes while hidden are pre-fetched when idle).
    func prepareForShow() {
        isPanelVisible = true
        referenceDate = Date()
        inlineEditor = nil
        editorText = ""
        draggingItemID = nil
        draggingPinboardID = nil

        var needsReload = isDirty
        if !searchText.isEmpty || !appliedSearch.isEmpty {
            searchText = ""
            appliedSearch = ""
            needsReload = true
        }
        if scope != .history {
            scope = .history
            needsReload = true
        }
        if kindFilter != .all {
            kindFilter = .all
            needsReload = true
        }
        if needsReload {
            reload(keepSelection: false)
        } else {
            setSelection(0, scroll: true)
        }
    }

    func panelDidHide() {
        isPanelVisible = false
        inlineEditor = nil
        draggingItemID = nil
        draggingPinboardID = nil
    }

    // MARK: Loading

    private func makeFilter(limit: Int, offset: Int) -> ClipFilter {
        return ClipFilter(
            kinds: kindFilter.kinds,
            pinboardID: currentPinboardID,
            searchText: appliedSearch,
            pinnedOnly: false,
            limit: limit,
            offset: offset
        )
    }

    private static func makeRows(_ items: [ClipItem], startIndex: Int) -> [PanelCardRow] {
        var result: [PanelCardRow] = []
        result.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            let identifier: UUID = item.id
            result.append(PanelCardRow(id: identifier, index: startIndex + offset, item: item))
        }
        return result
    }

    /// Re-fetches from offset 0. With `keepSelection` the already loaded count is kept
    /// (so the scroll position survives) and the selected item is tracked by ID.
    func reload(keepSelection: Bool) {
        refreshPinboards()
        let previousID = keepSelection ? selectedID : nil
        let limit = keepSelection ? max(Self.pageSize, rows.count) : Self.pageSize
        let fetched = store.fetchItems(makeFilter(limit: limit, offset: 0))
        rows = Self.makeRows(fetched, startIndex: 0)
        hasMore = fetched.count >= limit
        isDirty = false
        historyIsEmpty = fetched.isEmpty ? (store.itemCount() == 0) : false

        if let id = previousID, let index = rows.firstIndex(where: { $0.id == id }) {
            setSelection(index, scroll: false)
        } else if keepSelection {
            setSelection(min(selectedIndex, max(0, rows.count - 1)), scroll: false)
        } else {
            setSelection(0, scroll: true)
        }
    }

    /// Called from each card's onAppear; loads the next page near the end of the strip.
    func cardAppeared(at index: Int) {
        guard hasMore, index >= rows.count - Self.loadMoreThreshold else { return }
        loadMore()
    }

    private func loadMore() {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let page = store.fetchItems(makeFilter(limit: Self.pageSize, offset: rows.count))
        let existing = Set<UUID>(rows.map { $0.id })
        let fresh = page.filter { !existing.contains($0.id) }
        if !fresh.isEmpty {
            rows.append(contentsOf: Self.makeRows(fresh, startIndex: rows.count))
        }
        hasMore = page.count >= Self.pageSize
    }

    private func refreshPinboards() {
        let boards = store.pinboards()
        var result: [PanelPinboardRow] = []
        for board in boards {
            let identifier: UUID = board.id
            result.append(PanelPinboardRow(id: identifier, name: board.name, colorHex: board.colorHex))
        }
        if result != pinboardRows {
            pinboardRows = result
        }
        if let boardID = currentPinboardID, !result.contains(where: { $0.id == boardID }) {
            scope = .history
        }
    }

    private func storeDidChange() {
        if isPanelVisible {
            scheduleRefresh()
        } else {
            isDirty = true
            scheduleIdleRefresh()
        }
    }

    /// Coalesces bursts of store mutations into one reload on the next main-loop turn.
    /// (Never reload synchronously inside the store's `revision` willSet.)
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.refreshScheduled = false
            guard self.isPanelVisible else {
                self.isDirty = true
                return
            }
            self.reload(keepSelection: true)
            self.onSelectionChange?()
        }
    }

    /// While hidden, pre-fetch the first page shortly after the store settles, so the
    /// next show() does not have to fetch at all.
    private func scheduleIdleRefresh() {
        guard !idleRefreshScheduled else { return }
        idleRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self else { return }
            self.idleRefreshScheduled = false
            guard !self.isPanelVisible, self.isDirty else { return }
            self.resetFiltersSilently()
            self.reload(keepSelection: false)
        }
    }

    /// Puts filters in the state prepareForShow() will want, without reloading.
    private func resetFiltersSilently() {
        if !searchText.isEmpty { searchText = "" }
        appliedSearch = ""
        if scope != .history { scope = .history }
        if kindFilter != .all { kindFilter = .all }
    }

    // MARK: Filters

    private func applySearch(_ text: String) {
        guard text != appliedSearch else { return }
        appliedSearch = text
        guard isPanelVisible else {
            isDirty = true
            return
        }
        reload(keepSelection: false)
    }

    /// Esc with a query: clears it and reloads immediately (no debounce).
    func clearSearch() {
        searchText = ""
        if !appliedSearch.isEmpty {
            appliedSearch = ""
            reload(keepSelection: false)
        }
    }

    func setKindFilter(_ filter: PanelKindFilter) {
        guard filter != kindFilter else { return }
        kindFilter = filter
        reload(keepSelection: false)
    }

    func setScope(_ newScope: PanelScope) {
        guard newScope != scope else { return }
        scope = newScope
        reload(keepSelection: false)
    }

    // MARK: Selection

    private func setSelection(_ index: Int, scroll: Bool) {
        let clamped = rows.isEmpty ? 0 : min(max(index, 0), rows.count - 1)
        if clamped != selectedIndex {
            selectedIndex = clamped
        }
        selectedID = rows.indices.contains(clamped) ? rows[clamped].id : nil
        if scroll {
            scrollRequest &+= 1
        }
        onSelectionChange?()
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else {
            NSSound.beep()
            return
        }
        setSelection(selectedIndex + delta, scroll: true)
        if selectedIndex >= rows.count - Self.loadMoreThreshold {
            loadMore()
        }
    }

    func select(index: Int) {
        guard rows.indices.contains(index) else { return }
        setSelection(index, scroll: false)
    }

    /// Item for ⌘1…⌘9 / 1…9 (1-based, counted from the start of the current list).
    func item(forShortcut number: Int) -> ClipItem? {
        guard number >= 1, number <= Self.shortcutCount else { return nil }
        let index = number - 1
        guard rows.indices.contains(index) else { return nil }
        return rows[index].item
    }

    // MARK: Item actions

    /// Return / ⇧Return. Product decision (docs/API.md §8): ⇧ ALWAYS pastes as plain text;
    /// without ⇧ the "plain text by default" setting decides.
    func pasteSelected(shiftHeld: Bool) {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        paste(item, plainText: Self.wantsPlainText(shiftHeld: shiftHeld, settings: environment.settings))
    }

    static func wantsPlainText(shiftHeld: Bool, settings: AppSettings) -> Bool {
        return shiftHeld || settings.plainTextByDefault
    }

    func pasteShortcut(_ number: Int, shiftHeld: Bool) {
        guard let item = item(forShortcut: number) else {
            NSSound.beep()
            return
        }
        setSelection(number - 1, scroll: false)
        paste(item, plainText: Self.wantsPlainText(shiftHeld: shiftHeld, settings: environment.settings))
    }

    /// The paste service hides the panel, re-activates the previous app and sends ⌘V.
    func paste(_ item: ClipItem, plainText: Bool) {
        guard Self.isAlive(item) else { return }
        environment.paster.paste(item, asPlainText: plainText)
    }

    /// Double-click / context-menu "Paste": uses the default setting.
    func pasteWithDefault(_ item: ClipItem) {
        paste(item, plainText: environment.settings.plainTextByDefault)
    }

    func copySelected() {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        copy(item)
    }

    /// ⌘C / "Copy": pasteboard only, then close the panel.
    func copy(_ item: ClipItem) {
        guard Self.isAlive(item) else { return }
        environment.paster.copyToPasteboard(item, asPlainText: environment.settings.plainTextByDefault)
        presenter?.hide()
    }

    func togglePinSelected() {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        togglePin(item)
    }

    func togglePin(_ item: ClipItem) {
        guard Self.isAlive(item) else { return }
        store.togglePin(item)
    }

    func deleteSelected() {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        delete(item)
    }

    /// Removes the card locally first so no view renders a deleted model, then deletes.
    func delete(_ item: ClipItem) {
        guard Self.isAlive(item) else { return }
        guard let index = rows.firstIndex(where: { $0.item === item }) else {
            store.delete(item)
            return
        }
        var remaining = rows
        remaining.remove(at: index)
        rows = Self.reindexed(remaining)
        setSelection(min(index, max(0, rows.count - 1)), scroll: false)
        store.delete(item)
    }

    private static func reindexed(_ rows: [PanelCardRow]) -> [PanelCardRow] {
        var result: [PanelCardRow] = []
        result.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            result.append(PanelCardRow(id: row.id, index: offset, item: row.item))
        }
        return result
    }

    static func isAlive(_ item: ClipItem) -> Bool {
        return item.modelContext != nil && !item.isDeleted
    }

    // MARK: Pinboards

    private func pinboard(_ id: UUID) -> Pinboard? {
        return store.pinboard(withID: id)
    }

    func add(_ item: ClipItem, toPinboard boardID: UUID) {
        guard Self.isAlive(item), let board = pinboard(boardID) else { return }
        store.add(item, to: board)
    }

    func remove(_ item: ClipItem, fromPinboard boardID: UUID) {
        guard Self.isAlive(item), let board = pinboard(boardID) else { return }
        if currentPinboardID == boardID, let index = rows.firstIndex(where: { $0.item === item }) {
            var remaining = rows
            remaining.remove(at: index)
            rows = Self.reindexed(remaining)
            setSelection(min(index, max(0, rows.count - 1)), scroll: false)
        }
        store.remove(item, from: board)
    }

    func setColor(_ hex: String, forPinboard boardID: UUID) {
        guard let board = pinboard(boardID) else { return }
        store.setColor(hex, for: board)
        refreshPinboards()
    }

    func deletePinboard(_ boardID: UUID) {
        guard let board = pinboard(boardID) else { return }
        if currentPinboardID == boardID {
            scope = .history
        }
        store.deletePinboard(board)
        reload(keepSelection: false)
    }

    /// Next palette color not used yet (cycles when all are taken).
    private func nextPinboardColor() -> String {
        let palette = ClipConstants.pinboardPalette
        let used = Set(pinboardRows.map { $0.colorHex.uppercased() })
        if let free = palette.first(where: { !used.contains($0.uppercased()) }) {
            return free
        }
        guard !palette.isEmpty else { return ClipConstants.defaultPinboardColorHex }
        return palette[pinboardRows.count % palette.count]
    }

    // MARK: Inline editor (create / rename)

    func beginCreatePinboard(adding item: ClipItem? = nil) {
        let itemID: UUID? = item?.id
        editorText = ""
        inlineEditor = .newPinboard(addingItemID: itemID)
    }

    func beginRenamePinboard(_ boardID: UUID) {
        editorText = pinboardRows.first(where: { $0.id == boardID })?.name ?? ""
        inlineEditor = .renamePinboard(boardID)
    }

    func beginRename(_ item: ClipItem) {
        guard Self.isAlive(item) else { return }
        let itemID: UUID = item.id
        editorText = item.title ?? ""
        inlineEditor = .renameItem(itemID)
    }

    func cancelEditor() {
        inlineEditor = nil
        editorText = ""
        focusBridge.focusSearchField()
    }

    func commitEditor() {
        guard let editor = inlineEditor else { return }
        let text = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineEditor = nil
        editorText = ""
        switch editor {
        case .newPinboard(let addingItemID):
            let board = store.createPinboard(name: text.isEmpty ? "New Pinboard" : text, colorHex: nextPinboardColor())
            if let itemID = addingItemID, let item = store.item(withID: itemID) {
                store.add(item, to: board)
            }
            refreshPinboards()
        case .renamePinboard(let boardID):
            if !text.isEmpty, let board = pinboard(boardID) {
                store.renamePinboard(board, to: text)
                refreshPinboards()
            }
        case .renameItem(let itemID):
            if let item = store.item(withID: itemID) {
                store.setTitle(text.isEmpty ? nil : text, for: item)
            }
        }
        focusBridge.focusSearchField()
    }

    // MARK: Drag and drop (in-process)

    func beginItemDrag(_ item: ClipItem) -> NSItemProvider {
        draggingPinboardID = nil
        guard Self.isAlive(item) else { return NSItemProvider() }
        let itemID: UUID = item.id
        draggingItemID = itemID
        return PanelQuickLook.dragProvider(for: item, store: store)
    }

    func beginPinboardDrag(_ boardID: UUID) -> NSItemProvider {
        draggingItemID = nil
        draggingPinboardID = boardID
        let name = pinboardRows.first(where: { $0.id == boardID })?.name ?? "Pinboard"
        return NSItemProvider(object: name as NSString)
    }

    /// Drop on a pinboard tab: reorders when a tab is being dragged, adds the card when
    /// a card is being dragged. Drops from other apps are refused.
    func handleDrop(onPinboard targetID: UUID) -> Bool {
        defer {
            draggingItemID = nil
            draggingPinboardID = nil
        }
        if let movingID = draggingPinboardID {
            guard movingID != targetID,
                  let from = pinboardRows.firstIndex(where: { $0.id == movingID }),
                  let to = pinboardRows.firstIndex(where: { $0.id == targetID }) else { return false }
            store.movePinboard(from: from, to: to)
            refreshPinboards()
            return true
        }
        if let itemID = draggingItemID {
            guard let item = store.item(withID: itemID) else { return false }
            add(item, toPinboard: targetID)
            return true
        }
        return false
    }

    // MARK: Misc

    func openSettings() {
        presenter?.hide()
        NotificationCenter.default.post(name: .clipSyncOpenSettings, object: nil)
    }
}
