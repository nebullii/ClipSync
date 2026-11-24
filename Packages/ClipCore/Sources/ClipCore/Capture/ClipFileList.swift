import Foundation

/// THE format of the multi-file list stored in `ClipUTI.fileURLList` (pinned by the
/// integration pass, shared by the Mac clipboard monitor, the paste writer and the panel).
///
/// Format: UTF-8 text, one absolute `file://` URL string (`URL.absoluteString`) per line,
/// lines separated by "\n", no trailing newline. Only file URLs are written.
///
/// `decode(_:)` is deliberately tolerant so it can also read `public.file-url` payloads
/// written by other apps: `file://` lines, absolute paths, "\r\n" / NUL separators and
/// property-list arrays of paths (legacy `NSFilenamesPboardType`).
public enum ClipFileList {
    /// Encodes file URLs (non-file URLs are dropped).
    public static func encode(_ urls: [URL]) -> Data {
        let lines = urls.filter { $0.isFileURL }.map { $0.absoluteString }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Decodes data written by `encode(_:)` (or a tolerant superset, see type docs).
    /// Order is preserved; duplicates (same standardized path) are removed.
    public static func decode(_ data: Data) -> [URL] {
        guard !data.isEmpty else { return [] }
        var result: [URL] = []
        if let list = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String] {
            result = list.compactMap { url(fromLine: $0) }
        } else if let text = String(data: data, encoding: .utf8) {
            result = decode(text: text)
        }
        return unique(result)
    }

    /// Same as `decode(_:)` for text (e.g. a `.file` item's `plainText` of paths).
    public static func decode(text: String) -> [URL] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: "\u{0}"))
        let urls = text.components(separatedBy: separators).compactMap { url(fromLine: $0) }
        return unique(urls)
    }

    /// One line → file URL: "file://…" strings or absolute paths; anything else → nil.
    public static func url(fromLine line: String) -> URL? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("file:") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            return url
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            result.append(url)
        }
        return result
    }
}

extension ClipStore {
    /// File URLs of a `.file` item, best source first:
    /// 1. the internal `ClipUTI.fileURLList` representation (all copied files),
    /// 2. every `public.file-url` representation,
    /// 3. absolute paths / file URLs in `plainText` (one per line).
    /// Returns [] for items that carry file CONTENTS only (e.g. iOS share-extension
    /// file drafts, which store the bytes under the file's own UTI plus a title).
    public func fileURLs(for item: ClipItem) -> [URL] {
        if let data = data(for: item, uti: ClipUTI.fileURLList) {
            let urls = ClipFileList.decode(data)
            if !urls.isEmpty { return urls }
        }
        var fromReps: [URL] = []
        for rep in item.sortedRepresentations where rep.uti == ClipUTI.fileURL {
            if let bytes = data(for: rep) {
                fromReps.append(contentsOf: ClipFileList.decode(bytes))
            }
        }
        if !fromReps.isEmpty {
            return fromReps
        }
        if let text = item.plainText {
            return ClipFileList.decode(text: text)
        }
        return []
    }
}
