import Foundation
#if os(macOS)
import Security
#endif

/// App Group access that degrades gracefully when the build is unsigned.
public enum AppGroup {
    /// The App Group container URL, or nil when this process is not entitled.
    ///
    /// iOS: `containerURL(forSecurityApplicationGroupIdentifier:)` already returns nil
    /// without the entitlement.
    /// macOS: that API returns a URL even for unentitled processes, and on macOS 15+
    /// touching it can trigger a "would like to access data from other apps" prompt,
    /// so we first check the process's own entitlements.
    public static func containerURL() -> URL? {
        #if os(macOS)
        guard hasAppGroupEntitlement() else { return nil }
        #endif
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ClipConstants.appGroupID
        )
    }

    /// `UserDefaults(suiteName: appGroup) ?? .standard` (macOS: only when entitled).
    public static func userDefaults() -> UserDefaults {
        #if os(macOS)
        guard hasAppGroupEntitlement() else { return UserDefaults.standard }
        #endif
        return UserDefaults(suiteName: ClipConstants.appGroupID) ?? UserDefaults.standard
    }

    #if os(macOS)
    /// True when the running binary is signed with an application-groups entitlement
    /// that contains our group (plain or team-prefixed).
    public static func hasAppGroupEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.application-groups" as CFString,
            nil
        )
        guard let groups = value as? [String] else { return false }
        return groups.contains { $0 == ClipConstants.appGroupID || $0.hasSuffix(ClipConstants.appGroupID) }
    }
    #endif
}

/// Where the SwiftData store and the blob folder live on disk.
public struct StoreLocation: Sendable, Equatable {
    /// Folder containing the store file and the `Blobs/` folder.
    public let directory: URL
    /// The SwiftData SQLite file.
    public let storeURL: URL
    /// Folder for large representation blobs.
    public let blobsDirectory: URL
    /// True when `directory` is inside the App Group container.
    public let isAppGroup: Bool

    public init(directory: URL, isAppGroup: Bool) {
        self.directory = directory
        self.storeURL = directory.appendingPathComponent(ClipConstants.storeFileName, isDirectory: false)
        self.blobsDirectory = directory.appendingPathComponent(ClipConstants.blobsFolderName, isDirectory: true)
        self.isAppGroup = isAppGroup
    }

    /// App Group container if available, else `Application Support/ClipSync`
    /// (else the temporary directory as a last resort). Creates the folders.
    public static func resolve() -> StoreLocation {
        let fileManager = FileManager.default
        let location: StoreLocation
        if let group = AppGroup.containerURL() {
            location = StoreLocation(
                directory: group.appendingPathComponent(ClipConstants.storeFolderName, isDirectory: true),
                isAppGroup: true
            )
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            location = StoreLocation(
                directory: base.appendingPathComponent(ClipConstants.storeFolderName, isDirectory: true),
                isAppGroup: false
            )
        }
        try? fileManager.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: location.blobsDirectory, withIntermediateDirectories: true)
        // Owner-only permissions (0700 folders / 0600 files; iOS: data-protection class).
        // Best effort; see StoreFileProtection.
        StoreFileProtection.protectTree(at: location.directory)
        return location
    }

    /// A unique throwaway location under the temporary directory (tests, previews, in-memory stores).
    public static func temporary() -> StoreLocation {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipSync-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return StoreLocation(directory: dir, isAppGroup: false)
    }
}
