import SwiftUI
import ClipCore

/// Chooses the iPhone (tabs) or iPad (split view) layout and owns app-wide presentation:
/// toasts, onboarding, the pinboard editor, and scene-activation refreshes.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                PadRootView()
            } else {
                PhoneRootView()
            }
        }
        .tint(Theme.accent)
        .overlay {
            ToastOverlay(center: model.toasts)
        }
        .fullScreenCover(isPresented: $model.isOnboardingPresented) {
            OnboardingView(onFinish: { model.completeOnboarding() })
        }
        .sheet(item: $model.pinboardEditor) { mode in
            PinboardEditorView(mode: mode)
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.settings)
                .environmentObject(model.boards)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneBecameActive()
            }
        }
        .onReceive(model.store.$revision) { _ in
            model.boards.refresh(from: model.store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in
            model.cloud.refresh()
        }
    }
}

// MARK: - iPhone

enum PhoneTab: Hashable {
    case history, pinboards, settings
}

struct PhoneRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: PhoneTab = .history

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HistoryScreen(store: model.store, scope: .all, title: "ClipSync", showsCloudBanner: true)
            }
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .tag(PhoneTab.history)
            .accessibilityIdentifier("tab.history")

            PinboardsTab()
                .tabItem {
                    Label("Pinboards", systemImage: "pin.square")
                }
                .tag(PhoneTab.pinboards)
                .accessibilityIdentifier("tab.pinboards")

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(PhoneTab.settings)
            .accessibilityIdentifier("tab.settings")
        }
    }
}

// MARK: - iPad

enum SidebarItem: Hashable {
    case history
    case pinned
    case kind(KindFilter)
    case pinboard(UUID)
    case settings
}

struct PadRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .history
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PadSidebar(selection: $selection)
                .navigationTitle("ClipSync")
        } detail: {
            NavigationStack {
                PadDetail(selection: selection ?? .history)
                    .id(selection ?? .history)
            }
        }
    }
}

private struct PadSidebar: View {
    @Binding var selection: SidebarItem?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var directory: PinboardDirectory
    @State private var pendingDelete: Pinboard? = nil

    private var sidebarKinds: [KindFilter] {
        return KindFilter.allCases.filter { $0 != .all }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.history)
                    .accessibilityIdentifier("sidebar.history")
                Label("Pinned", systemImage: "pin.fill")
                    .tag(SidebarItem.pinned)
                    .accessibilityIdentifier("sidebar.pinned")
            }
            Section("Kinds") {
                ForEach(sidebarKinds) { filter in
                    Label(filter.title, systemImage: filter.systemImage)
                        .tag(SidebarItem.kind(filter))
                        .accessibilityIdentifier("sidebar.kind.\(filter.rawValue)")
                }
            }
            Section("Pinboards") {
                ForEach(directory.boards) { board in
                    PinboardRowLabel(board: board)
                        .tag(SidebarItem.pinboard(board.id))
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
                    Label("New Pinboard", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("sidebar.newPinboard")
            }
            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
                    .accessibilityIdentifier("sidebar.settings")
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .modifier(PinboardDeleteConfirmation(pendingDelete: $pendingDelete))
        .onChange(of: directory.boards.map { $0.id }) { _, ids in
            if case .pinboard(let id)? = selection, !ids.contains(id) {
                selection = .history
            }
        }
    }
}

private struct PadDetail: View {
    let selection: SidebarItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch selection {
        case .history:
            HistoryScreen(store: model.store, scope: .all, title: "History", showsCloudBanner: true)
        case .pinned:
            HistoryScreen(store: model.store, scope: .pinned, title: "Pinned", showsSaveBar: false)
        case .kind(let filter):
            HistoryScreen(store: model.store, scope: .all, title: filter.title, initialKind: filter, showsKindFilter: false)
        case .pinboard(let id):
            PinboardScreen(boardID: id)
        case .settings:
            SettingsView()
        }
    }
}
