import Foundation

/// File-system hardening for the on-disk history (database + blob files).
///
/// - POSIX permissions: data folders 0700, files 0600 — readable only by the user account
///   that runs ClipSync. Other user accounts on the same Mac cannot read the history.
///   (It does NOT stop software running as the same user; see docs/SECURITY.md.)
/// - iOS: Data Protection class `completeUntilFirstUserAuthentication` on the folders and
///   files. Not `.complete`: the share extension, Shortcuts and iCloud sync must be able
///   to write while the device is locked, and `.complete` would make the database
///   unreadable to them then (SQLite would fail). So files are encrypted with a key that
///   is unavailable after a restart until the first unlock, and available afterwards.
///
/// Every call is best effort and never throws: a failure leaves the system defaults
/// (which on macOS are already inside the per-user ~/Library).
public enum StoreFileProtection {
    public static let directoryPermissions = 0o700
    public static let filePermissions = 0o600

    /// Options for writing payload files (iOS adds the data-protection class).
    public static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    /// Attributes for creating data directories.
    public static var directoryAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: directoryPermissions)]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        return attributes
    }

    /// 0700 (+ iOS protection class) on a directory.
    public static func protectDirectory(_ url: URL) {
        try? FileManager.default.setAttributes(directoryAttributes, ofItemAtPath: url.path)
    }

    /// 0600 (+ iOS protection class) on a file.
    public static func protectFile(_ url: URL) {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: filePermissions)]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// Protects `directory` itself and everything below it (database, WAL/SHM files,
    /// SwiftData external-storage files, blobs). Symbolic links are skipped.
    public static func protectTree(at directory: URL) {
        protectDirectory(directory)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                protectDirectory(url)
            } else {
                protectFile(url)
            }
        }
    }

    /// The POSIX permission bits of a file or folder (tests, diagnostics).
    public static func permissions(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.posixPermissions] as? NSNumber else { return nil }
        return number.intValue & 0o777
    }
}
