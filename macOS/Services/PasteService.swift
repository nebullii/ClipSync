import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ClipCore
import os   // Logger interpolation (privacy:) used via ServicesLog

/// `PasteActing` implementation: writes the item to the general pasteboard, returns
/// focus to the app the user was in, and sends ⌘V.
///
/// Without Accessibility permission the synthetic keystroke cannot be delivered, so
/// `paste` degrades to copy-only (the user presses ⌘V themselves).
@MainActor
final class PasteService: PasteActing {
    private weak var environment: AppEnvironment?
    private let tracker: FrontmostAppTracker
    private let writer: PasteboardWriter
    /// Told about every write so the clipboard monitor ignores it.
    private let onOwnWrite: (Int) -> Void
    /// Called when a paste fell back to copy-only because Accessibility is missing.
    var onAccessibilityMissing: (() -> Void)?

    init(environment: AppEnvironment, tracker: FrontmostAppTracker, onOwnWrite: @escaping (Int) -> Void) {
        self.environment = environment
        self.tracker = tracker
        self.writer = PasteboardWriter(store: environment.store)
        self.onOwnWrite = onOwnWrite
    }

    var hasAccessibilityPermission: Bool {
        return AXIsProcessTrusted()
    }

    /// App Lock: nothing is written while ClipSync is locked (defense in depth; the panel,
    /// menu bar and test driver already refuse). Checked BEFORE hiding the panel, because
    /// hiding can lock ("Immediately" timeout).
    private var isLocked: Bool {
        return environment?.appLock.isLocked ?? false
    }

    func paste(_ item: ClipItem, asPlainText: Bool) {
        guard !isLocked else { return }
        environment?.appLock.noteActivity()
        environment?.panel.hide()
        let target = tracker.pasteTarget
        writeToPasteboard(item, asPlainText: asPlainText)

        guard hasAccessibilityPermission else {
            ServicesLog.paste.info("Accessibility not granted: copied only")
            onAccessibilityMissing?()
            return
        }

        let needsActivation = activate(target)
        // Give the target app time to become key (and the panel time to order out)
        // before the keystroke arrives.
        let delay: UInt64 = needsActivation ? 250_000_000 : 80_000_000
        Task {
            try? await Task.sleep(nanoseconds: delay)
            PasteService.postCommandV()
        }
    }

    func copyToPasteboard(_ item: ClipItem, asPlainText: Bool) {
        guard !isLocked else { return }
        environment?.appLock.noteActivity()
        writeToPasteboard(item, asPlainText: asPlainText)
    }

    private func writeToPasteboard(_ item: ClipItem, asPlainText: Bool) {
        let changeCount = writer.write(item, asPlainText: asPlainText)
        onOwnWrite(changeCount)
        environment?.store.markUsed(item)
    }

    // MARK: - Activation

    /// Brings `target` to the front if needed. Returns true when an activation was requested.
    private func activate(_ target: NSRunningApplication?) -> Bool {
        guard let target = target, !target.isTerminated else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if NSApp.isActive {
            // macOS 14 cooperative activation: hand activation over explicitly.
            NSApp.yieldActivation(to: target)
            _ = target.activate(options: [])
            return true
        }
        if frontPID != target.processIdentifier || frontPID == ownPID {
            _ = target.activate(options: [])
            return true
        }
        return false
    }

    // MARK: - Keystroke

    /// Posts ⌘V (key down + key up) to the HID event tap.
    static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keep the user's physical keys (e.g. a still-held ⇧ from ⇧↩) out of the keystroke.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let keyCode = KeyCodeResolver.keyCode(forCharacter: "v") ?? CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            ServicesLog.paste.error("Could not create CGEvents for ⌘V")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

/// Finds the virtual key code that types a character in the current keyboard layout
/// (so ⌘V works on Dvorak, AZERTY, ...). Falls back to nil for non-Latin layouts,
/// where apps match shortcuts by the ANSI key position anyway.
enum KeyCodeResolver {
    @MainActor
    static func keyCode(forCharacter character: String) -> CGKeyCode? {
        let wanted = character.lowercased()
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        return layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let base = buffer.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                let maxLength = 4
                var characters = [UniChar](repeating: 0, count: maxLength)
                let status = UCKeyTranslate(
                    layout,
                    UInt16(code),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    keyboardType,
                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    maxLength,
                    &length,
                    &characters
                )
                guard status == 0, length > 0 else { continue }
                let produced = String(utf16CodeUnits: characters, count: length).lowercased()
                if produced == wanted {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
