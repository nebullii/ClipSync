import Foundation

/// Content-addressed file storage for large representation payloads.
/// Files are named by the SHA-256 hex of their bytes, so identical payloads share a file.
/// Blob files are local to the device (not synced by CloudKit).
public struct BlobStore: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A BlobStore in a fresh temporary folder (tests / in-memory stores).
    public static func temporary() -> BlobStore {
        return BlobStore(directory: StoreLocation.temporary().blobsDirectory)
    }

    /// Writes `data` (if not already present) and returns its file name.
    @discardableResult
    public func write(_ data: Data) throws -> String {
        let name = ContentHasher.sha256Hex(data)
        let url = fileURL(for: name)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            return name
        }
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: StoreFileProtection.directoryAttributes
            )
        }
        try data.write(to: url, options: StoreFileProtection.writeOptions)
        // Owner-only (0600); best effort, never fails the write.
        StoreFileProtection.protectFile(url)
        return name
    }

    /// The bytes for `fileName`, or nil when missing/unreadable/invalid name.
    public func read(_ fileName: String) -> Data? {
        guard BlobStore.isValidFileName(fileName) else { return nil }
        return try? Data(contentsOf: fileURL(for: fileName))
    }

    public func exists(_ fileName: String) -> Bool {
        guard BlobStore.isValidFileName(fileName) else { return false }
        return FileManager.default.fileExists(atPath: fileURL(for: fileName).path)
    }

    /// Removes the file (ignores errors and invalid names).
    public func delete(_ fileName: String) {
        guard BlobStore.isValidFileName(fileName) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: fileName))
    }

    /// URL of a blob (e.g. for Quick Look or file-promise drags). Does not check existence.
    public func fileURL(for fileName: String) -> URL {
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// All blob file names currently on disk.
    public func allFileNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { BlobStore.isValidFileName($0) }
    }

    /// Rejects names that could escape the directory.
    public static func isValidFileName(_ name: String) -> Bool {
        return !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".")
    }
}
