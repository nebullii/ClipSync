import AppKit
import ClipCore
import os   // Logger interpolation (privacy:) used via ServicesLog

/// Runs `store.runMaintenance()` (retention, max count, blob GC) at launch, once a day,
/// after waking from sleep when a day has passed, and on demand.
@MainActor
final class MaintenanceScheduler: NSObject {
    static let interval: TimeInterval = 24 * 60 * 60

    private let store: ClipStore
    private var timer: Timer?
    private var lastRun: Date?

    init(store: ClipStore) {
        self.store = store
        super.init()
    }

    func start() {
        runNow()
        guard timer == nil else { return }
        let newTimer = Timer(
            timeInterval: MaintenanceScheduler.interval,
            target: self,
            selector: #selector(timerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        newTimer.tolerance = 60 * 60
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func runNow() {
        let removed = store.runMaintenance()
        lastRun = Date()
        if removed > 0 {
            ServicesLog.app.info("Maintenance removed \(removed) items/blobs")
        }
    }

    @objc private func timerFired(_ timer: Timer) {
        runNow()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // Timers do not fire while asleep; catch up if the Mac slept through a run.
        if let last = lastRun, Date().timeIntervalSince(last) < MaintenanceScheduler.interval { return }
        runNow()
    }
}
