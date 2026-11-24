import AppKit
import KeyboardShortcuts

/// Registers the global hotkey (`KeyboardShortcuts.Name.togglePanel`, default ⇧⌘V).
/// The user changes the shortcut with `KeyboardShortcuts.Recorder` in Settings /
/// onboarding; KeyboardShortcuts persists it and keeps this handler attached.
@MainActor
final class HotkeyController {
    private var isRegistered = false

    func register(environment: AppEnvironment) {
        guard !isRegistered else { return }
        isRegistered = true
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak environment] in
            environment?.panel.toggle()
        }
    }
}
