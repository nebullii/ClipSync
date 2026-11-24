import Foundation

/// Identifiers shared by every target. Never hard-code these strings elsewhere.
public enum ClipConstants {
    public static let appGroupID = "group.com.thingbits.clipsync"
    public static let iCloudContainerID = "iCloud.com.thingbits.clipsync"
    public static let macBundleID = "com.thingbits.clipsync.mac"
    public static let iOSBundleID = "com.thingbits.clipsync.ios"
    public static let shareExtensionBundleID = "com.thingbits.clipsync.ios.share"

    /// Folder name used under Application Support / the App Group container.
    public static let storeFolderName = "ClipSync"
    /// SQLite file name of the SwiftData store.
    public static let storeFileName = "ClipSync.store"
    /// Folder (sibling of the store file) holding large representation blobs.
    public static let blobsFolderName = "Blobs"

    /// Default pinboard color (a neutral blue).
    public static let defaultPinboardColorHex = "#3B82F6"
    /// Suggested pinboard palette for color pickers (uppercase #RRGGBB).
    public static let pinboardPalette: [String] = [
        "#3B82F6", "#22C55E", "#EAB308", "#F97316",
        "#EF4444", "#A855F7", "#EC4899", "#6B7280"
    ]
}

/// Small text helpers used by the store and UI.
public enum ClipText {
    /// First non-empty line of `text`, trimmed and cut to `maxLength` characters.
    /// Returns nil when the text has no visible characters.
    public static func derivedTitle(from text: String?, maxLength: Int = 200) -> String? {
        guard let text = text else { return nil }
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                if line.count > maxLength {
                    return String(line.prefix(maxLength))
                }
                return line
            }
        }
        return nil
    }

    /// Normalizes line endings to "\n" (no trimming).
    public static func normalizeLineEndings(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
