// Owned by the Mac panel UI engineer.
//
// The PanelPresenting implementation: one reusable, non-activating, borderless NSPanel
// hosting the SwiftUI card strip.
//
// Show/hide
//   show(): picks the screen under the mouse, sets the frame (full width of its
//   visibleFrame, ~300 pt tall, along the bottom), orders the panel front WITHOUT
//   activating ClipSync (orderFrontRegardless + makeKey on a .nonactivatingPanel), focuses
//   the search field and runs a short slide/fade. The previous app stays the active app,
//   which is what the paste service needs before it sends ⌘V.
//   hide(): immediate orderOut (no fade) so the paste service can send ⌘V right away.
//   Hidden by: Esc, a click outside (global monitor = other apps, local monitor = other
//   windows of ClipSync), and windowDidResignKey.
//
// Keyboard routing
//   One local keyDown monitor, installed only while the panel is visible, sees every key
//   event before the search field does. It consumes navigation/command keys (arrows,
//   Return, Esc, Space, Delete, ⌘1–9, ⌘C, ⌘P, …) and lets everything else through.
//   Printable keys first make sure the AppKit search field is first responder (caret at
//   the end), then pass through — that is type-to-search from anywhere in the panel.
//
// App Lock (security pass)
//   While env.appLock.isLocked the panel shows only PanelLockView, the view model holds no
//   rows, and the key monitor swallows every key except Esc / ⌘W (hide) and Return / Space
//   (unlock). Quick Look is closed and its temp files removed on lock. The panel still
//   opens from the hotkey, and prompts for Touch ID / password once per show.

import AppKit
import SwiftUI
import SwiftData
import Combine
import Quartz
import QuartzCore
import ClipCore

// MARK: - The window

/// Borderless, non-activating panel that can still become key (so the search field
/// receives typing) without activating the ClipSync app.
final class CardStripPanel: NSPanel {
    /// Data source for Quick Look; the panel is the Quick Look controller (responder chain).
    var quickLookSource: PanelQuickLookDataSource?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        isMovable = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        setAccessibilityLabel("ClipSync clipboard history")
    }

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    // Quick Look panel controller (found through the key window's responder chain).
    // These override NSObject(QLPreviewPanelController) category methods, which are not
    // actor-annotated, so they are declared nonisolated and hop onto the main actor
    // explicitly (Quick Look always calls them on the main thread).
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self.quickLookSource
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
        }
    }
}

// MARK: - Key codes (hardware positions; layout independent)

private enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let forwardDelete: UInt16 = 117
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    /// Number-row and keypad digit keys → 1…9 (used with ⌘ so it works on any layout).
    static func digit(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18, 83: return 1
        case 19, 84: return 2
        case 20, 85: return 3
        case 21, 86: return 4
        case 23, 87: return 5
        case 22, 88: return 6
        case 26, 89: return 7
        case 28, 91: return 8
        case 25, 92: return 9
        default: return nil
        }
    }
}

// MARK: - Controller

@MainActor
final class PanelController: NSObject, PanelPresenting, NSWindowDelegate {
    static let panelHeight: CGFloat = 300
    static let screenInset: CGFloat = 8
    static let cornerRadius: CGFloat = 18

    private let environment: AppEnvironment
    private let viewModel: PanelViewModel
    private let panel: CardStripPanel
    private let quickLookSource = PanelQuickLookDataSource()
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private(set) var isVisible = false
    /// Synchronous cost of the last full show() in ms (frame, fetch, order front; not the fade). -1 = never shown.
    private(set) var lastShowDurationMs: Double = -1

    /// E2E test hook (macOS/App/E2E/E2EDriver.swift): the driver routes its commands through this view model.
    var e2eViewModel: PanelViewModel { return viewModel }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.viewModel = PanelViewModel(environment: environment)
        self.panel = CardStripPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: PanelController.panelHeight))
        super.init()

        panel.delegate = self
        panel.quickLookSource = quickLookSource
        viewModel.presenter = self
        viewModel.onSelectionChange = { [weak self] in
            self?.refreshQuickLookIfVisible()
        }
        PanelQuickLook.removeTemporaryFiles()
        installContent()

        environment.appLock.addLockStateObserver { [weak self] locked in
            self?.lockStateChanged(locked)
        }
    }

    private func installContent() {
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1200, height: PanelController.panelHeight))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = PanelChrome.roundedMaskImage(cornerRadius: PanelController.cornerRadius)
        effect.autoresizingMask = [.width, .height]

        let root = PanelRootView(
            viewModel: viewModel,
            appLock: environment.appLock,
            onUnlock: { [weak self] in self?.unlockFromPanel() }
        )
            .environmentObject(environment)
            .environmentObject(environment.store)
            .environmentObject(environment.settings)
            .modelContainer(environment.store.container)
        let hosting = NSHostingView(rootView: root)
        // The window size is ours; never let SwiftUI's ideal size resize the panel.
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        panel.contentView = effect
        // Build the SwiftUI hierarchy now, so the first show() does not pay for it.
        effect.layoutSubtreeIfNeeded()
    }

    // MARK: PanelPresenting

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let locked = environment.appLock.checkTimeout()
        if isVisible {
            panel.makeKey()
            if !locked {
                viewModel.focusBridge.focusSearchField()
            }
            return
        }
        let showStarted = CACurrentMediaTime()
        let target = PanelController.targetFrame(on: PanelController.screenUnderMouse())
        viewModel.prepareForShow()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var start = target
        if !reduceMotion {
            start.origin.y -= 24
        }
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        isVisible = true
        installMonitors()

        if locked {
            if environment.appLock.autoPromptOnShow {
                // Once per show; the user can press Return / the button to try again.
                Task { @MainActor [weak self] in
                    self?.unlockFromPanel()
                }
            }
        } else if !viewModel.focusBridge.focusSearchField() {
            // First show: the hosted NSSearchField may only exist after the first layout pass.
            Task { @MainActor [weak self] in
                self?.viewModel.focusBridge.focusSearchField()
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.08 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(target, display: true)
            self.panel.animator().alphaValue = 1
        }
        lastShowDurationMs = (CACurrentMediaTime() - showStarted) * 1000
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        closeQuickLook()
        viewModel.panelDidHide()
        panel.orderOut(nil)
        panel.alphaValue = 1
        // "Immediately" locks now; other timeouts start counting from here.
        environment.appLock.noteInterfaceHidden()
    }

    // MARK: App Lock

    private func lockStateChanged(_ locked: Bool) {
        if locked {
            closeQuickLook()
            PanelQuickLook.removeTemporaryFiles()
            viewModel.lockContent()
        } else if isVisible {
            viewModel.prepareForShow()
            panel.makeKey()
            if !viewModel.focusBridge.focusSearchField() {
                Task { @MainActor [weak self] in
                    self?.viewModel.focusBridge.focusSearchField()
                }
            }
        }
    }

    /// Lock screen button / Return / Space / auto-prompt on show.
    private func unlockFromPanel() {
        let lock = environment.appLock
        guard lock.isLocked, !lock.isAuthenticating else { return }
        // The strip sits at status-bar level; drop it while the system prompt is up so the
        // Touch ID / password dialog can never end up behind it.
        let normalLevel = panel.level
        panel.level = .floating
        Task { @MainActor [weak self] in
            let unlocked = await lock.unlock(reason: "show your clipboard history")
            guard let self = self else { return }
            self.panel.level = normalLevel
            guard self.isVisible else { return }
            // The system prompt took key status; give it back to the strip.
            self.panel.makeKey()
            if unlocked {
                self.viewModel.focusBridge.focusSearchField()
            }
        }
    }

    // MARK: Geometry

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func targetFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let inset = screenInset
        let height = min(panelHeight, max(200, visible.height - 2 * inset))
        return NSRect(
            x: visible.minX + inset,
            y: visible.minY + inset,
            width: max(400, visible.width - 2 * inset),
            height: height
        )
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            return self.handleLocalEvent(event)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // A click in another app (or on the desktop). Not while the system
            // authentication prompt (another process) is up: clicks there are expected.
            guard let self = self, !self.environment.appLock.isAuthenticating else { return }
            self.hide()
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }
        if event.type == .keyDown {
            return handleKeyDown(event)
        }
        // Mouse down in one of ClipSync's own windows.
        guard let window = event.window else { return event }
        if window === panel || window is QLPreviewPanel {
            return event
        }
        // Context menus run their own tracking; never treat menu windows as "outside".
        if window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue {
            return event
        }
        hide()
        return event
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let quickLookVisible = PanelQuickLook.isPanelVisible
        let isOurWindow = event.window === panel || (quickLookVisible && event.window is QLPreviewPanel)
        guard isOurWindow else { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if environment.appLock.isLocked {
            return handleLockedKeyDown(event, flags: flags)
        }
        environment.appLock.noteActivity()
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let vm = viewModel

        // While the inline rename/create field is active it gets all typing.
        if vm.inlineEditor != nil {
            switch event.keyCode {
            case KeyCode.escape:
                vm.cancelEditor()
                return nil
            case KeyCode.returnKey, KeyCode.keypadEnter:
                vm.commitEditor()
                return nil
            default:
                return event
            }
        }

        switch event.keyCode {
        case KeyCode.escape:
            if quickLookVisible {
                closeQuickLook()
            } else if !vm.searchText.isEmpty {
                vm.clearSearch()
            } else {
                hide()
            }
            return nil
        case KeyCode.leftArrow:
            vm.moveSelection(by: -1)
            return nil
        case KeyCode.rightArrow:
            vm.moveSelection(by: 1)
            return nil
        case KeyCode.returnKey, KeyCode.keypadEnter:
            vm.pasteSelected(shiftHeld: shift)
            return nil
        case KeyCode.space:
            if quickLookVisible || vm.isSearchEmpty {
                toggleQuickLook()
                return nil
            }
            return event
        case KeyCode.delete, KeyCode.forwardDelete:
            if command || vm.isSearchEmpty {
                vm.deleteSelected()
                return nil
            }
            return event
        default:
            break
        }

        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if command && !control && !option {
            if let number = KeyCode.digit(for: event.keyCode) {
                vm.pasteShortcut(number, shiftHeld: shift)
                return nil
            }
            switch characters {
            case "c":
                if vm.focusBridge.searchFieldHasSelection {
                    return event          // copy the selected search text instead
                }
                vm.copySelected()
                return nil
            case "p":
                vm.togglePinSelected()
                return nil
            case "f":
                vm.focusBridge.focusSearchField()
                return nil
            case ",":
                vm.openSettings()
                return nil
            case "w":
                hide()
                return nil
            default:
                return event              // ⌘A, ⌘V, ⌘X, ⌘Z… go to the search field
            }
        }

        if command || control {
            return event
        }

        // Plain 1–9 paste only while the query is empty (layout-aware: uses the typed character).
        if vm.isSearchEmpty && !option, let typed = event.characters, typed.count == 1,
           let number = Int(typed), number >= 1, number <= PanelViewModel.shortcutCount {
            vm.pasteShortcut(number, shiftHeld: shift)
            return nil
        }

        if PanelController.isTypingEvent(event) {
            vm.focusBridge.focusSearchField()
        }
        return event
    }

    /// While locked nothing reaches the (hidden) content: no search typing, no ⌘1–9,
    /// no paste/copy/Quick Look. Esc / ⌘W hide, Return / Space unlock; all else is swallowed.
    private func handleLockedKeyDown(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.escape:
            hide()
        case KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.space:
            unlockFromPanel()
        default:
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags.contains(.command) && characters == "w" {
                hide()
            }
        }
        return nil
    }

    private static func isTypingEvent(_ event: NSEvent) -> Bool {
        if event.specialKey != nil { return false }
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        // Clicking into the Quick Look panel makes it key; keep the strip open then.
        if PanelQuickLook.isPanelVisible { return }
        // The Touch ID / password prompt takes key status; keep the lock screen up.
        if environment.appLock.isAuthenticating { return }
        hide()
    }

    // MARK: Quick Look

    private func toggleQuickLook() {
        if PanelQuickLook.isPanelVisible {
            closeQuickLook()
            return
        }
        guard !environment.appLock.isLocked else { return }
        guard let item = viewModel.selectedItem, PanelViewModel.isAlive(item) else {
            NSSound.beep()
            return
        }
        let urls = PanelQuickLook.previewURLs(for: item, store: environment.store)
        guard !urls.isEmpty, let preview = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        quickLookSource.urls = urls
        // Same screen-capture setting as the strip (AppController.applyWindowPrivacy).
        preview.sharingType = panel.sharingType
        preview.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        preview.updateController()
        if preview.dataSource == nil {
            // Responder-chain lookup did not reach the strip panel; attach directly.
            preview.dataSource = quickLookSource
        }
        preview.reloadData()
        // orderFront (not makeKey): the strip stays key, so our key monitor keeps working.
        preview.orderFront(nil)
    }

    private func refreshQuickLookIfVisible() {
        guard isVisible, PanelQuickLook.isPanelVisible, let preview = QLPreviewPanel.shared() else { return }
        guard let item = viewModel.selectedItem, PanelViewModel.isAlive(item) else {
            closeQuickLook()
            return
        }
        quickLookSource.urls = PanelQuickLook.previewURLs(for: item, store: environment.store)
        preview.reloadData()
    }

    private func closeQuickLook() {
        guard PanelQuickLook.isPanelVisible, let preview = QLPreviewPanel.shared() else { return }
        preview.orderOut(nil)
        if isVisible {
            panel.makeKey()
        }
    }
}

// MARK: - Window chrome helpers (nonisolated, no actor state)

enum PanelChrome {
    /// Stretchable rounded-rect mask for NSVisualEffectView.maskImage.
    static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = 2 * cornerRadius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
