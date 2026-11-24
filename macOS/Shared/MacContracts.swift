// CONTRACT — owned by the foundation engineer. Both Mac engineers code against
// these types; neither side references the other's concrete classes.
//
//   Mac services engineer (macOS/App, macOS/Services): implements PasteActing,
//     creates AppEnvironment at launch, owns the hotkey, menu bar, monitor.
//   Mac panel UI engineer (macOS/Panel): implements PanelPresenting and returns it
//     from PanelFactory.makePanel(environment:) (macOS/Panel/PanelFactory.swift).
//
// Change this file only by agreement of both engineers.

import AppKit
import Combine
import ClipCore
import KeyboardShortcuts

/// Shows/hides the bottom-of-screen card strip.
@MainActor
protocol PanelPresenting: AnyObject {
    /// True while the panel is on screen.
    var isVisible: Bool { get }
    /// show() if hidden, hide() if visible.
    func toggle()
    /// Shows the panel on the screen that contains the mouse cursor, focused on search.
    func show()
    /// Hides the panel without pasting.
    func hide()
}

/// Writes items to the pasteboard and pastes into the previously active app.
@MainActor
protocol PasteActing: AnyObject {
    /// True when Accessibility permission (needed for the synthetic ⌘V) is granted.
    var hasAccessibilityPermission: Bool { get }
    /// Hides the panel (via AppEnvironment.panel), writes the item to the general
    /// pasteboard, re-activates the previous app and sends ⌘V. Calls store.markUsed.
    /// Falls back to copyToPasteboard when Accessibility is not granted.
    func paste(_ item: ClipItem, asPlainText: Bool)
    /// Writes the item to the general pasteboard only (no keystroke). Calls store.markUsed.
    /// Must not be re-captured by the clipboard monitor as a new item (dedup bumps it anyway).
    func copyToPasteboard(_ item: ClipItem, asPlainText: Bool)
}

/// Everything the Mac UI needs, created once by the services side at launch.
@MainActor
final class AppEnvironment: ObservableObject {
    let store: ClipStore
    let settings: AppSettings
    /// Replaced by the services engineer's paste service at launch.
    var paster: PasteActing
    /// Replaced with PanelFactory.makePanel(environment:) at launch.
    var panel: PanelPresenting

    init(store: ClipStore, settings: AppSettings, paster: PasteActing? = nil, panel: PanelPresenting? = nil) {
        self.store = store
        self.settings = settings
        self.paster = paster ?? NoopPaster()
        self.panel = panel ?? NoopPanelPresenter()
    }

    /// Process-wide environment. Launch code should configure it like:
    ///
    ///     let env = AppEnvironment.shared
    ///     env.paster = PasteService(environment: env)          // services engineer
    ///     env.panel = PanelFactory.makePanel(environment: env)  // panel engineer
    static let shared = AppEnvironment(store: ClipStore.shared, settings: AppSettings.shared)
}

/// Global hotkey names shared by the hotkey handler (services) and settings UI.
extension KeyboardShortcuts.Name {
    /// Default ⇧⌘V. Toggles the panel.
    static let togglePanel = Self("togglePanel", default: .init(.v, modifiers: [.command, .shift]))
}

/// Notifications both sides may post/observe.
extension Notification.Name {
    /// Posted by the panel when the user asks to open Settings. Observed by the services
    /// side (AppController), which opens the Settings window.
    ///
    /// Optional deep link: `userInfo[ClipSyncNotificationKey.settingsTab]` (= "tab") is a
    /// String naming the tab to select: "general", "history", "privacy", "sync" or "about"
    /// (case-insensitive). Missing / unknown → the window opens on its current tab.
    ///
    ///     NotificationCenter.default.post(name: .clipSyncOpenSettings, object: nil,
    ///                                     userInfo: [ClipSyncNotificationKey.settingsTab: "privacy"])
    ///
    /// Post on the main thread.
    static let clipSyncOpenSettings = Notification.Name("ClipSyncOpenSettings")
}

/// userInfo keys of the notifications above (plain strings, usable from any thread).
enum ClipSyncNotificationKey {
    /// `.clipSyncOpenSettings`: optional String tab name (see above).
    static let settingsTab = "tab"
}

// MARK: - Placeholders so the target compiles before the real implementations exist.

@MainActor
final class NoopPaster: PasteActing {
    var hasAccessibilityPermission: Bool { return false }
    func paste(_ item: ClipItem, asPlainText: Bool) {}
    func copyToPasteboard(_ item: ClipItem, asPlainText: Bool) {}
}

@MainActor
final class NoopPanelPresenter: PanelPresenting {
    private(set) var isVisible: Bool = false
    func toggle() { isVisible.toggle() }
    func show() { isVisible = true }
    func hide() { isVisible = false }
}
