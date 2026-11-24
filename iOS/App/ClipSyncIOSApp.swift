import SwiftUI
import SwiftData
import ClipCore

/// ClipSync for iPhone and iPad.
///
/// Launch arguments (automated Simulator tests):
/// - `-uitest-seed`: in-memory store, onboarding skipped, ~12 sample clips + 2 pinboards.
/// - `-uitest-skip-onboarding`: real store, onboarding not shown (setting not changed).
@main
@MainActor
struct ClipSyncIOSApp: App {
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.settings)
                .environmentObject(model.boards)
                .environmentObject(model.appLock)
                .modelContainer(model.store.container)
        }
    }
}
