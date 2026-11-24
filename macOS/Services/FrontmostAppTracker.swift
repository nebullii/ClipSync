import AppKit

/// Remembers the last app other than ClipSync that was frontmost, so a paste can
/// go back to it after the panel (or a ClipSync window) was shown.
@MainActor
final class FrontmostAppTracker: NSObject {
    /// The most recently activated app that is not ClipSync (may have quit since).
    private(set) var previousApp: NSRunningApplication?

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            previousApp = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    /// The app a paste should go to: the current frontmost app if it is not ClipSync,
    /// else the last other app that was active (if it is still running).
    var pasteTarget: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            return front
        }
        if let app = previousApp, !app.isTerminated {
            return app
        }
        return nil
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.processIdentifier != ownPID else { return }
        previousApp = app
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if previousApp?.processIdentifier == app.processIdentifier {
            previousApp = nil
        }
    }
}
