import Foundation
import SwiftUI
import UIKit
import Combine
import CoreData
import ClipCore

extension Notification.Name {
    /// Posted when the store may have changed outside this process's `revision`
    /// (Share Extension / Shortcuts writes, CloudKit imports, scene re-activation).
    static let clipSyncIOSExternalChange = Notification.Name("com.thingbits.clipsync.ios.externalChange")
}

/// Launch arguments used by automated Simulator tests.
enum LaunchOptions {
    static var arguments: [String] {
        return ProcessInfo.processInfo.arguments
    }

    /// In-memory store + sample data + no onboarding.
    static var isUITestSeed: Bool {
        return arguments.contains("-uitest-seed")
    }

    static var skipsOnboarding: Bool {
        return isUITestSeed || arguments.contains("-uitest-skip-onboarding")
    }

    /// `@AppStorage` key of the History list/grid choice (see HistoryScreen).
    static let historyLayoutKey = "clipsync.ios.historyLayout"
}

/// Requests for the shared pinboard editor sheet (presented once, at the root).
enum PinboardEditorMode: Identifiable {
    case create(adding: ClipItem?)
    case edit(Pinboard)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let board):
            return "edit-" + board.id.uuidString
        }
    }
}

/// App-wide state and the actions rows/cards call. Views that only call actions observe
/// this object, which publishes rarely (sheet requests), never on every store mutation.
@MainActor
final class AppModel: ObservableObject {
    let store: ClipStore
    let settings: AppSettings
    let toasts = ToastCenter()
    let boards = PinboardDirectory()
    let cloud = CloudStatusMonitor()
    let isUITest: Bool

    @Published var isOnboardingPresented: Bool
    @Published var pinboardEditor: PinboardEditorMode? = nil

    private var cancellables = Set<AnyCancellable>()

    init(store: ClipStore, settings: AppSettings, isUITest: Bool, skipOnboarding: Bool) {
        self.store = store
        self.settings = settings
        self.isUITest = isUITest
        self.isOnboardingPresented = !skipOnboarding && !settings.hasCompletedOnboarding

        // CloudKit imports and other processes writing to the store. The closure only posts
        // a notification, so it needs no actor isolation.
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { _ in
                NotificationCenter.default.post(name: .clipSyncIOSExternalChange, object: nil)
            }
            .store(in: &cancellables)

        boards.refresh(from: store)
        cloud.refresh()
    }

    /// Builds the store for this launch (UI-test seed or the real shared store).
    static func bootstrap() -> AppModel {
        if LaunchOptions.isUITestSeed {
            let suiteName = "com.thingbits.clipsync.uitest"
            let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults.standard
            defaults.removePersistentDomain(forName: suiteName)
            let settings = AppSettings(defaults: defaults)
            settings.hasCompletedOnboarding = true
            // Deterministic layout: History shows list rows ("history.row.N") on every device,
            // even if an earlier run switched to the grid (@AppStorage uses .standard).
            UserDefaults.standard.set(HistoryLayout.list.rawValue, forKey: LaunchOptions.historyLayoutKey)
            let store = ClipStore.makeShared(inMemory: true, cloudSync: false)
            store.settings = settings
            store.deviceName = UIDevice.current.name
            ClipStore.setShared(store)
            SampleData.seed(into: store)
            return AppModel(store: store, settings: settings, isUITest: true, skipOnboarding: true)
        }

        let settings = AppSettings.shared
        let store = ClipStore.shared
        store.deviceName = UIDevice.current.name
        store.media = .live()
        store.runMaintenance()
        return AppModel(
            store: store,
            settings: settings,
            isUITest: false,
            skipOnboarding: LaunchOptions.skipsOnboarding
        )
    }

    // MARK: - Lifecycle

    func sceneBecameActive() {
        cloud.refresh()
        store.runMaintenance()
        refreshFromStore()
    }

    /// Re-reads everything (pull to refresh, foregrounding, external writes).
    func refreshFromStore() {
        boards.refresh(from: store)
        NotificationCenter.default.post(name: .clipSyncIOSExternalChange, object: nil)
    }

    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        isOnboardingPresented = false
    }

    func showOnboarding() {
        isOnboardingPresented = true
    }

    // MARK: - Item actions

    func copy(_ item: ClipItem, plainTextOnly: Bool = false) {
        guard item.isAlive else { return }
        let feedback = UINotificationFeedbackGenerator()
        if PasteboardWriter.write(item, store: store, plainTextOnly: plainTextOnly) {
            feedback.notificationOccurred(.success)
            store.markUsed(item)
            toasts.show(plainTextOnly ? "Copied as plain text" : "Copied", systemImage: "doc.on.doc.fill")
        } else {
            feedback.notificationOccurred(.error)
            toasts.show("Nothing to copy", systemImage: "exclamationmark.triangle.fill", style: .warning)
        }
    }

    func togglePin(_ item: ClipItem) {
        guard item.isAlive else { return }
        let willPin = !item.isPinned
        store.togglePin(item)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        toasts.show(willPin ? "Pinned" : "Unpinned", systemImage: willPin ? "pin.fill" : "pin.slash", style: .info)
    }

    func delete(_ item: ClipItem) {
        guard item.isAlive else { return }
        store.delete(item)
        toasts.show("Deleted", systemImage: "trash.fill", style: .info)
    }

    func toggle(_ item: ClipItem, in board: Pinboard) {
        guard item.isAlive else { return }
        if item.isMember(of: board) {
            store.remove(item, from: board)
            toasts.show("Removed from \(board.name)", systemImage: "minus.circle.fill", style: .info)
        } else {
            store.add(item, to: board)
            toasts.show("Added to \(board.name)", systemImage: "pin.square.fill", style: .info)
        }
        boards.refresh(from: store)
    }

    func remove(_ item: ClipItem, from board: Pinboard) {
        guard item.isAlive else { return }
        store.remove(item, from: board)
        boards.refresh(from: store)
        toasts.show("Removed from \(board.name)", systemImage: "minus.circle.fill", style: .info)
    }

    // MARK: - Pinboards

    func requestNewPinboard(adding item: ClipItem? = nil) {
        pinboardEditor = .create(adding: item)
    }

    func requestEdit(_ board: Pinboard) {
        pinboardEditor = .edit(board)
    }

    @discardableResult
    func createPinboard(name: String, colorHex: String, adding item: ClipItem?) -> Pinboard {
        let board = store.createPinboard(name: name, colorHex: colorHex)
        if let item = item, item.isAlive {
            store.add(item, to: board)
        }
        boards.refresh(from: store)
        toasts.show("Created \(board.name)", systemImage: "pin.square.fill", style: .info)
        return board
    }

    func updatePinboard(_ board: Pinboard, name: String, colorHex: String) {
        store.renamePinboard(board, to: name)
        store.setColor(colorHex, for: board)
        boards.refresh(from: store)
    }

    func deletePinboard(_ board: Pinboard) {
        let name = board.name
        store.deletePinboard(board)
        boards.refresh(from: store)
        toasts.show("Deleted \(name)", systemImage: "trash.fill", style: .info)
    }

    func movePinboards(fromOffsets source: IndexSet, toOffset destination: Int) {
        store.movePinboards(fromOffsets: source, toOffset: destination)
        boards.refresh(from: store)
    }

    // MARK: - Save clipboard (UIPasteControl)

    func saveFromPaste(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else {
            toasts.show("The clipboard is empty", systemImage: "clipboard", style: .warning)
            return
        }
        Task { @MainActor in
            let output = await ClipboardDraftBuilder.build(from: providers)
            self.ingest(output)
        }
    }

    /// Ingests drafts and reports "Saved" / "Already in history" / why nothing was saved.
    func ingest(_ output: ClipboardDraftBuilder.Output) {
        var inserted = 0
        var bumped = 0
        var rejections: [IngestRejection] = []
        for draft in output.drafts {
            switch store.ingestDetailed(draft) {
            case .inserted(let item):
                inserted += 1
                Task { @MainActor in
                    await self.store.enrich(item)
                }
            case .bumped:
                bumped += 1
            case .rejected(let reason):
                rejections.append(reason)
            }
        }

        let feedback = UINotificationFeedbackGenerator()
        if inserted > 0 {
            feedback.notificationOccurred(.success)
            let message = inserted == 1 ? "Saved" : "Saved \(inserted) items"
            toasts.show(message, systemImage: "tray.and.arrow.down.fill")
        } else if bumped > 0 {
            feedback.notificationOccurred(.success)
            toasts.show("Already in history — moved to top", systemImage: "arrow.up.circle.fill", style: .info)
        } else {
            feedback.notificationOccurred(.warning)
            toasts.show(AppModel.message(rejections: rejections, skipped: output.skipped),
                        systemImage: "exclamationmark.triangle.fill", style: .warning)
        }
    }

    private static func message(rejections: [IngestRejection], skipped: [SkipReason]) -> String {
        if rejections.contains(.markerType) || skipped.contains(.concealed) || skipped.contains(.transient) {
            return "Not saved: the source app marked it private"
        }
        if rejections.contains(.tooLarge) {
            return "Too large to save"
        }
        if rejections.contains(.ignoredApp) {
            return "Not saved: the source app is ignored"
        }
        if skipped.contains(.unsupported) {
            return "This kind of content isn't supported yet"
        }
        return "Nothing to save on the clipboard"
    }

    // MARK: - History maintenance

    @discardableResult
    func clearHistory(keepPinned: Bool) -> Int {
        let removed = store.clearHistory(keepPinned: keepPinned)
        ThumbnailCache.shared.removeAll()
        boards.refresh(from: store)
        let noun = removed == 1 ? "clip" : "clips"
        toasts.show("Cleared \(removed) \(noun)", systemImage: "trash.fill", style: .info)
        return removed
    }
}

/// Cached, ordered pinboards for menus and the sidebar. Republishes only when something
/// visible (id, name, color, count, order) changed.
@MainActor
final class PinboardDirectory: ObservableObject {
    @Published private(set) var boards: [Pinboard] = []
    private var signature: [String] = []

    func refresh(from store: ClipStore) {
        let fresh = store.pinboards()
        let newSignature = fresh.map { board in
            "\(board.id.uuidString)|\(board.name)|\(board.colorHex)|\(board.itemCount)"
        }
        if newSignature != signature {
            signature = newSignature
            boards = fresh
        }
    }

    func board(withID id: UUID) -> Pinboard? {
        return boards.first { $0.id == id }
    }
}

/// iCloud account availability (`ubiquityIdentityToken`) plus a per-session banner dismissal.
@MainActor
final class CloudStatusMonitor: ObservableObject {
    @Published private(set) var isICloudSignedIn = false
    @Published var isBannerDismissed = false

    func refresh() {
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        if signedIn != isICloudSignedIn {
            isICloudSignedIn = signedIn
        }
    }
}
