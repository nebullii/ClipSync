import SwiftUI
import ClipCore

enum PinboardRoute: Hashable {
    case pinned
    case board(UUID)
}

/// iPhone "Pinboards" tab: Pinned + user pinboards (create, rename, color, delete, reorder).
struct PinboardsTab: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            PinboardListView()
                .navigationTitle("Pinboards")
                .navigationDestination(for: PinboardRoute.self) { route in
                    PinboardRouteView(route: route)
                }
        }
    }
}

struct PinboardRouteView: View {
    let route: PinboardRoute
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch route {
        case .pinned:
            HistoryScreen(store: model.store, scope: .pinned, title: "Pinned", showsSaveBar: false)
        case .board(let id):
            PinboardScreen(boardID: id)
        }
    }
}

private struct PinboardListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var directory: PinboardDirectory
    @State private var pendingDelete: Pinboard? = nil

    var body: some View {
        List {
            Section {
                NavigationLink(value: PinboardRoute.pinned) {
                    Label("Pinned", systemImage: "pin.fill")
                }
                .accessibilityIdentifier("pinboards.pinned")
            }
            Section {
                ForEach(directory.boards) { board in
                    NavigationLink(value: PinboardRoute.board(board.id)) {
                        PinboardRowLabel(board: board)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = board
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            model.requestEdit(board)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.gray)
                    }
                    .contextMenu {
                        PinboardContextMenu(board: board, onDelete: { pendingDelete = board })
                    }
                }
                .onMove { source, destination in
                    model.movePinboards(fromOffsets: source, toOffset: destination)
                }
                Button {
                    model.requestNewPinboard()
                } label: {
                    Label("New Pinboard", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("pinboards.new")
            } header: {
                Text("Pinboards")
            } footer: {
                Text("Clips in a pinboard are never removed by history cleanup.")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.requestNewPinboard()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New pinboard")
            }
        }
        .modifier(PinboardDeleteConfirmation(pendingDelete: $pendingDelete))
        .accessibilityIdentifier("pinboards.list")
    }
}

/// Name, color dot and item count.
struct PinboardRowLabel: View {
    let board: Pinboard

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "pin.square.fill")
                .font(.title3)
                .foregroundStyle(Color(clipHex: board.colorHex))
                .accessibilityHidden(true)
            Text(board.name)
            Spacer(minLength: 4)
            Text("\(board.itemCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(board.name), \(board.itemCount) clips")
    }
}

struct PinboardContextMenu: View {
    let board: Pinboard
    let onDelete: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.requestEdit(board)
        } label: {
            Label("Rename or Recolor", systemImage: "pencil")
        }
        Button(role: .destructive, action: onDelete) {
            Label("Delete Pinboard", systemImage: "trash")
        }
    }
}

/// "Delete pinboard?" confirmation (clips stay in history).
struct PinboardDeleteConfirmation: ViewModifier {
    @Binding var pendingDelete: Pinboard?
    @EnvironmentObject private var model: AppModel

    private var isPresented: Binding<Bool> {
        return Binding(
            get: { pendingDelete != nil },
            set: { presented in
                if !presented {
                    pendingDelete = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete this pinboard?",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { board in
            Button("Delete \(board.name)", role: .destructive) {
                model.deletePinboard(board)
                pendingDelete = nil
            }
        } message: { _ in
            Text("Its clips stay in your history.")
        }
    }
}

/// One pinboard's clips, with edit and add-items buttons.
struct PinboardScreen: View {
    let boardID: UUID
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var directory: PinboardDirectory
    @State private var showingPicker = false

    var body: some View {
        if let board = directory.board(withID: boardID) {
            HistoryScreen(
                store: model.store,
                scope: .pinboard(boardID),
                title: board.name,
                board: board,
                showsSaveBar: false
            )
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add clips")
                    .accessibilityIdentifier("pinboard.addItems")
                    Button {
                        model.requestEdit(board)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit pinboard")
                }
            }
            .sheet(isPresented: $showingPicker) {
                NavigationStack {
                    PinboardItemPicker(board: board)
                }
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.settings)
                .environmentObject(model.boards)
            }
        } else {
            ContentUnavailableView("Pinboard not found", systemImage: "pin.slash")
        }
    }
}

/// Searchable history list with a checkmark per clip: tap toggles membership in `board`.
struct PinboardItemPicker: View {
    let board: Pinboard
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: HistoryViewModel

    init(board: Pinboard) {
        self.board = board
        _viewModel = StateObject(wrappedValue: HistoryViewModel(store: ClipStore.shared, scope: .all))
    }

    var body: some View {
        List {
            ForEach(viewModel.items) { item in
                PinboardPickerRow(item: item, board: board)
                    .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.items.isEmpty {
                ContentUnavailableView("No clips", systemImage: "doc.on.clipboard")
            }
        }
        .searchable(text: $viewModel.searchText, prompt: Text("Search clips"))
        .navigationTitle("Add to \(board.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: viewModel.searchText) {
            if viewModel.isSearching {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if Task.isCancelled { return }
            }
            viewModel.resetAndReload()
        }
        .onReceive(model.store.$revision) { _ in
            viewModel.reload()
        }
    }
}

private struct PinboardPickerRow: View {
    let item: ClipItem
    let board: Pinboard
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if item.isAlive {
            let member = item.isMember(of: board)
            Button {
                model.toggle(item, in: board)
            } label: {
                HStack(spacing: 12) {
                    ClipLeadingVisual(item: item, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        Text(item.metaLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: member ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(member ? Theme.accent : Color.secondary)
                        .font(.title3)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityValue(Text((member ? "In pinboard" : "Not in pinboard") as String))
            .accessibilityAddTraits(member ? [.isButton, .isSelected] : [.isButton])
        }
    }
}
