import AppKit
import ClipCore
import os   // Logger interpolation (privacy:) used via ServicesLog

/// Watches `NSPasteboard.general` and records every change into the store.
///
/// - Polls `changeCount` every 400 ms (tolerance 150 ms, `.common` run-loop mode so it
///   keeps running while menus track). An unchanged count costs one cheap call.
/// - On a change it checks pause state, marker types and ignored apps on the main
///   thread (cheap, and nothing is read from password managers), then reads the
///   data on a serial background queue (`PasteboardReader`) and hops back to the
///   main actor to ingest. Stale reads (pasteboard changed meanwhile) are dropped;
///   the newer change is picked up by the next tick.
/// - Stops while the Mac sleeps or the user session is switched out; resumes after.
@MainActor
final class ClipboardMonitor: NSObject {
    struct Capture {
        let kind: ClipKind
        let plainText: String?
        let date: Date
        let wasInserted: Bool
    }

    static let pollInterval: TimeInterval = 0.4

    private let store: ClipStore
    private let settings: AppSettings
    private let limits: PasteboardReadLimits
    private let readQueue = DispatchQueue(label: "com.thingbits.clipsync.pasteboard-read", qos: .utility)

    private var timer: Timer?
    private var lastChangeCount: Int
    /// changeCounts produced by ClipSync's own writes (never captured).
    private var ownChangeCounts: [Int] = []
    private var isStarted = false
    private var isSuspended = false

    /// The most recent successful capture (inserted or bumped).
    private(set) var lastCapture: Capture?
    /// Called on the main actor after every successful capture.
    var onCapture: ((Capture) -> Void)?

    init(store: ClipStore, settings: AppSettings, limits: PasteboardReadLimits = PasteboardReadLimits()) {
        self.store = store
        self.settings = settings
        self.limits = limits
        self.lastChangeCount = NSPasteboard.general.changeCount
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Whatever is on the pasteboard at launch was copied before we ran: not captured.
        lastChangeCount = NSPasteboard.general.changeCount
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        startTimer()
    }

    func stop() {
        isStarted = false
        stopTimer()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Call right after ClipSync itself wrote to the pasteboard.
    func noteOwnWrite(changeCount: Int) {
        ownChangeCounts.append(changeCount)
        if ownChangeCounts.count > 16 {
            ownChangeCounts.removeFirst(ownChangeCounts.count - 16)
        }
    }

    /// Checks the pasteboard immediately (e.g. after resuming capture).
    func checkNow() {
        poll()
    }

    // MARK: - Timer

    private func startTimer() {
        guard timer == nil, isStarted, !isSuspended else { return }
        let newTimer = Timer(
            timeInterval: ClipboardMonitor.pollInterval,
            target: self,
            selector: #selector(timerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        newTimer.tolerance = 0.15
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func timerFired(_ timer: Timer) {
        poll()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        isSuspended = true
        stopTimer()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        isSuspended = false
        startTimer()
        // Something may have arrived while asleep (e.g. Universal Clipboard): look now.
        poll()
    }

    // MARK: - Polling

    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if let index = ownChangeCounts.firstIndex(of: changeCount) {
            ownChangeCounts.remove(at: index)
            return
        }
        // Pause is a monitor rule (the store does not check it): changes made while
        // paused are skipped for good, not captured on resume.
        guard !settings.capturePaused else { return }

        // Cheap, main-thread privacy checks before any payload is read.
        let topTypes = (pasteboard.types ?? []).map { $0.rawValue }
        if topTypes.contains(PasteboardMarkers.ownWrite) { return }
        if PasteboardTypeClassifier.markerSkipReason(for: topTypes) != nil { return }

        let source = sourceApp(pasteboard: pasteboard, types: topTypes)
        if settings.ignoreRules.shouldIgnore(bundleID: source.bundleID) { return }
        if let front = source.frontmostBundleID, front != source.bundleID,
           settings.ignoreRules.shouldIgnore(bundleID: front) {
            return
        }

        let context = PasteboardCaptureContext(
            changeCount: changeCount,
            sourceAppBundleID: source.bundleID,
            sourceAppName: source.name
        )
        let limits = self.limits
        // The monitor lives for the whole process, so capturing self strongly is fine.
        readQueue.async {
            let outcome = PasteboardReader.read(context, limits: limits)
            Task { @MainActor in
                self.finish(outcome, changeCount: changeCount)
            }
        }
    }

    private struct SourceApp {
        var bundleID: String?
        var name: String?
        var frontmostBundleID: String?
    }

    /// The app that wrote the pasteboard: `org.nspasteboard.source` when the writer
    /// declares it, else the frontmost app.
    private func sourceApp(pasteboard: NSPasteboard, types: [String]) -> SourceApp {
        let front = NSWorkspace.shared.frontmostApplication
        var result = SourceApp(
            bundleID: front?.bundleIdentifier,
            name: front?.localizedName,
            frontmostBundleID: front?.bundleIdentifier
        )
        if types.contains(ClipUTI.source),
           let declared = pasteboard.string(forType: NSPasteboard.PasteboardType(ClipUTI.source))?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !declared.isEmpty,
           declared.count < 256 {
            if declared != result.bundleID {
                result.bundleID = declared
                result.name = AppNames.displayName(forBundleID: declared)
            }
        }
        return result
    }

    private func finish(_ outcome: PasteboardReadOutcome, changeCount: Int) {
        switch outcome {
        case .stale:
            return
        case .skipped(let reason):
            ServicesLog.monitor.debug("Skipped change \(changeCount): \(reason, privacy: .public)")
            return
        case .draft(let draft):
            // Paused while the read was in flight → drop.
            guard !settings.capturePaused else { return }
            let result = store.ingestDetailed(draft)
            switch result {
            case .inserted(let item):
                // OCR / thumbnails / link titles (no-op until the Media layer is live).
                let store = self.store
                Task { await store.enrich(item) }
                report(draft: draft, inserted: true)
            case .bumped:
                report(draft: draft, inserted: false)
            case .rejected(let rejection):
                ServicesLog.monitor.debug("Store rejected change \(changeCount): \(rejection.rawValue, privacy: .public)")
            }
        }
    }

    private func report(draft: ClipDraft, inserted: Bool) {
        let capture = Capture(kind: draft.kind, plainText: draft.plainText, date: Date(), wasInserted: inserted)
        lastCapture = capture
        onCapture?(capture)
    }
}
