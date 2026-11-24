import Foundation
import ClipCore
import os   // Logger interpolation (privacy:) used via ServicesLog

/// Test hook: writes a one-line JSON status to
/// `~/Library/Application Support/ClipSync/status.json`.
///
/// Only active in DEBUG builds launched with `CLIPSYNC_UITEST=1 CLIPSYNC_STATUS_FILE=1`
/// (see LaunchOptions); otherwise every call is a no-op (the file can hold a snippet of
/// clipboard text — redacted while App Lock has ClipSync locked).
@MainActor
final class StatusFileWriter {
    struct Status: Codable, Equatable {
        var itemCount: Int
        var capturePaused: Bool
        var accessibilityGranted: Bool
        var lastCapturedKind: String?
        var lastCapturedTextPrefix: String?
        var timestamp: String
    }

    let isEnabled: Bool
    private let fileURL: URL?

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        if isEnabled,
           let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            fileURL = base
                .appendingPathComponent("ClipSync", isDirectory: true)
                .appendingPathComponent("status.json", isDirectory: false)
        } else {
            fileURL = nil
        }
    }

    func write(
        store: ClipStore,
        settings: AppSettings,
        accessibilityGranted: Bool,
        lastCapture: ClipboardMonitor.Capture?,
        redactContent: Bool = false
    ) {
        guard isEnabled, let fileURL = fileURL else { return }
        let prefix: String?
        if redactContent {
            prefix = lastCapture?.plainText == nil ? nil : "<redacted>"
        } else if let text = lastCapture?.plainText {
            prefix = String(text.prefix(40))
        } else {
            prefix = nil
        }
        let status = Status(
            itemCount: store.itemCount(),
            capturePaused: settings.capturePaused,
            accessibilityGranted: accessibilityGranted,
            lastCapturedKind: lastCapture?.kind.rawValue,
            lastCapturedTextPrefix: prefix,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(status)   // compact = one line
            data.append(0x0A)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            ServicesLog.app.error("Could not write status file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
