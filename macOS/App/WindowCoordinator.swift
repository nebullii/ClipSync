import AppKit
import SwiftUI
import ClipCore

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, history, privacy, sync, about
    var id: String { rawValue }
}

/// Which settings tab is showing (lets the menu / onboarding open a specific tab).
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

enum OnboardingStep: Int, CaseIterable, Hashable {
    case welcome = 0
    case accessibility = 1
    case finish = 2
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome
}

/// Creates and shows the Settings and Onboarding windows.
///
/// Plain NSWindows hosting SwiftUI rather than the SwiftUI `Settings` scene: in a
/// menu-bar-only (LSUIElement) app the Settings scene cannot be opened reliably from
/// AppKit code on macOS 14+, and it would need the app to activate first anyway.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private unowned let controller: AppController
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    /// Windows currently holding an Accessibility live-update request.
    private var liveUpdateWindows = Set<ObjectIdentifier>()
    let settingsSelection = SettingsSelection()
    let onboardingModel = OnboardingModel()

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    // MARK: - Settings

    func showSettings(tab: SettingsTab? = nil) {
        if let tab = tab {
            settingsSelection.tab = tab
        }
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let root = SettingsRootView(selection: settingsSelection)
                .environmentObject(controller)
                .environmentObject(controller.store)
                .environmentObject(controller.settings)
                .environmentObject(controller.accessibility)
                .environmentObject(controller.launchAtLogin)
            window = makeWindow(rootView: root, title: "ClipSync Settings", autosaveName: "ClipSyncSettingsWindow")
            settingsWindow = window
        }
        present(window)
    }

    // MARK: - Onboarding

    func showOnboarding(step: OnboardingStep) {
        onboardingModel.step = step
        let window: NSWindow
        if let existing = onboardingWindow {
            window = existing
        } else {
            let root = OnboardingView(model: onboardingModel)
                .environmentObject(controller)
                .environmentObject(controller.settings)
                .environmentObject(controller.accessibility)
                .environmentObject(controller.launchAtLogin)
            window = makeWindow(rootView: root, title: "Welcome to ClipSync", autosaveName: nil)
            onboardingWindow = window
        }
        present(window)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === onboardingWindow {
            // Closing the welcome window counts as done; it is reachable again from the menu.
            if !controller.settings.hasCompletedOnboarding {
                controller.settings.hasCompletedOnboarding = true
            }
        }
        if liveUpdateWindows.remove(ObjectIdentifier(window)) != nil {
            controller.accessibility.endLiveUpdates()
        }
    }

    // MARK: - Private

    private func makeWindow<Content: View>(rootView: Content, title: String, autosaveName: String?) -> NSWindow {
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        if let autosaveName = autosaveName {
            window.setFrameAutosaveName(autosaveName)
        }
        return window
    }

    private func present(_ window: NSWindow) {
        if liveUpdateWindows.insert(ObjectIdentifier(window)).inserted {
            // Balanced by endLiveUpdates() in windowWillClose.
            controller.accessibility.beginLiveUpdates()
        }
        // An agent app must activate itself before its window can become key.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
