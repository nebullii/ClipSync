// Mac app entry point — owned by the Mac services engineer.
//
// Launch wiring:
//   ClipSyncMacApp.init        → AppController.shared (swaps in an in-memory store first
//                                when CLIPSYNC_UITEST=1, then binds AppEnvironment.shared)
//   applicationDidFinishLaunching → AppController.start(): env.paster / env.panel, hotkey,
//                                monitor, maintenance, login item, onboarding, test hooks.

import AppKit
import SwiftUI
import ClipCore

@main
@MainActor
struct ClipSyncMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let controller: AppController

    init() {
        controller = AppController.shared
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(
                controller: controller,
                store: controller.store,
                settings: controller.settings,
                accessibility: controller.accessibility
            )
        } label: {
            MenuBarLabel(settings: controller.settings)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }

    /// Opening ClipSync again from Finder / Spotlight while it runs shows Settings
    /// (a menu-bar app has no other window to show).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppController.shared.openSettings()
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
