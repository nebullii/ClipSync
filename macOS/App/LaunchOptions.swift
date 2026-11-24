import Foundation

/// Hidden switches read from the process environment at launch.
///
/// These exist for automated end-to-end testing only and are never set by a normal launch.
/// Security fence: CLIPSYNC_STATUS_FILE and CLIPSYNC_E2E_DIR work only in DEBUG builds AND
/// only together with CLIPSYNC_UITEST=1 (in-memory store, wiped settings). Release / Signed
/// builds contain no status writer call and no E2E command channel at all.
///   CLIPSYNC_UITEST=1        in-memory history store, onboarding is not shown
///   CLIPSYNC_SHOW_PANEL=1    shows the panel ~1 s after launch
///   CLIPSYNC_STATUS_FILE=1   (DEBUG + CLIPSYNC_UITEST=1 only) writes
///                            ~/Library/Application Support/ClipSync/status.json after every capture
///   CLIPSYNC_E2E_DIR=<abs>   (only together with CLIPSYNC_UITEST=1) E2E driver: status files,
///                            command channel and window snapshots in that folder
///                            (macOS/App/E2E/E2EDriver.swift, scripts/e2e-mac.sh)
struct LaunchOptions: Sendable, Equatable {
    var isUITest: Bool
    var showPanelAfterLaunch: Bool
    var writesStatusFile: Bool
    /// Absolute folder for the E2E driver; nil unless CLIPSYNC_UITEST=1 and CLIPSYNC_E2E_DIR is absolute.
    var e2eDirectory: String?

    static let current = LaunchOptions(environment: ProcessInfo.processInfo.environment)

    init(environment: [String: String]) {
        isUITest = LaunchOptions.flag("CLIPSYNC_UITEST", in: environment)
        showPanelAfterLaunch = LaunchOptions.flag("CLIPSYNC_SHOW_PANEL", in: environment)
        #if DEBUG
        writesStatusFile = isUITest && LaunchOptions.flag("CLIPSYNC_STATUS_FILE", in: environment)
        let e2ePath = (environment["CLIPSYNC_E2E_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        e2eDirectory = (isUITest && e2ePath.hasPrefix("/")) ? e2ePath : nil
        #else
        writesStatusFile = false
        e2eDirectory = nil
        #endif
    }

    private static func flag(_ name: String, in environment: [String: String]) -> Bool {
        guard let raw = environment[name] else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }
}
