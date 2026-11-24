import AppKit
import ApplicationServices
import Combine
import os   // Logger interpolation (privacy:) used via ServicesLog

/// Accessibility (AX) trust, needed to send the synthetic ⌘V.
///
/// `isGranted` is re-checked once per second while any client has called
/// `beginLiveUpdates()` (onboarding / settings windows visible), and whenever
/// ClipSync becomes active.
@MainActor
final class AccessibilityPermission: NSObject, ObservableObject {
    @Published private(set) var isGranted: Bool

    private var liveUpdateClients = 0
    private var timer: Timer?

    override init() {
        isGranted = AXIsProcessTrusted()
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// Re-reads the current trust state.
    func refresh() {
        let granted = AXIsProcessTrusted()
        if granted != isGranted {
            isGranted = granted
        }
    }

    /// Shows the system "ClipSync would like to control this computer" prompt (only
    /// appears if ClipSync is not trusted yet) and adds ClipSync to the list.
    func requestPrompt() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt; the
        // literal avoids touching the imported global (a concurrency warning in newer SDKs).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isGranted = AXIsProcessTrustedWithOptions(options)
        beginTemporaryPolling()
    }

    /// Opens System Settings › Privacy & Security › Accessibility.
    func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                beginTemporaryPolling()
                return
            }
        }
        ServicesLog.app.error("Could not open Accessibility settings")
    }

    /// Starts 1 s polling (balanced by `endLiveUpdates()`).
    func beginLiveUpdates() {
        liveUpdateClients += 1
        refresh()
        startTimerIfNeeded()
    }

    func endLiveUpdates() {
        liveUpdateClients = max(0, liveUpdateClients - 1)
        if liveUpdateClients == 0 && temporaryPollingDeadline == nil {
            stopTimer()
        }
    }

    // MARK: - Private

    /// After a prompt or a trip to System Settings, keep polling for two minutes even
    /// if no window asked for live updates (so the menu bar state catches up).
    private var temporaryPollingDeadline: Date?

    private func beginTemporaryPolling() {
        temporaryPollingDeadline = Date().addingTimeInterval(120)
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 1.0, target: self, selector: #selector(timerFired(_:)), userInfo: nil, repeats: true)
        newTimer.tolerance = 0.3
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func timerFired(_ timer: Timer) {
        refresh()
        if let deadline = temporaryPollingDeadline {
            if isGranted || Date() > deadline {
                temporaryPollingDeadline = nil
            }
        }
        if liveUpdateClients == 0 && temporaryPollingDeadline == nil {
            stopTimer()
        }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        refresh()
    }
}
