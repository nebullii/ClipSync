import AppKit
import UniformTypeIdentifiers
import os

/// Unified-logging categories for the Mac services. Never log clipboard contents.
enum ServicesLog {
    static let subsystem = "com.thingbits.clipsync.mac"
    static let monitor = Logger(subsystem: ServicesLog.subsystem, category: "monitor")
    static let paste = Logger(subsystem: ServicesLog.subsystem, category: "paste")
    static let app = Logger(subsystem: ServicesLog.subsystem, category: "app")
}

/// Small helpers for naming apps by bundle identifier.
enum AppNames {
    /// Location of an installed app, or nil when Launch Services does not know it.
    static func applicationURL(forBundleID bundleID: String) -> URL? {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("*") else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed)
    }

    /// Display name for an installed app ("Safari"), or nil when it cannot be found.
    static func displayName(forBundleID bundleID: String) -> String? {
        guard let url = applicationURL(forBundleID: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") {
            return String(name.dropLast(4))
        }
        return name
    }

    /// The app's Finder icon, or a generic app icon when it cannot be found.
    static func icon(forBundleID bundleID: String) -> NSImage {
        if let url = applicationURL(forBundleID: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
