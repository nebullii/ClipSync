import AppKit
import ClipCore
import os   // Logger interpolation (privacy:) used via ServicesLog

/// ClipSync's own pasteboard type names (plain constants, usable from any thread).
/// The identifiers live in ClipCore (`ClipUTI`) so every target agrees on them.
enum PasteboardMarkers {
    /// Added to everything ClipSync writes so the monitor never re-captures its own writes.
    /// Starts with `ClipUTI.internalPrefix`, so it is never stored either.
    static let ownWrite = ClipUTI.ownWrite

    /// Internal representation holding every copied file URL when more than one file was
    /// copied, in the `ClipFileList` format (encode/decode in ClipCore). Internal prefix →
    /// excluded from `pasteboardPayload(for:)` and from the content hash; the writer expands
    /// it into one pasteboard item per file.
    static let fileURLList = ClipUTI.fileURLList
}

/// Writes a stored `ClipItem` back to a pasteboard.
@MainActor
struct PasteboardWriter {
    let store: ClipStore

    /// Writes `item` and returns the pasteboard's `changeCount` after the write
    /// (hand it to `ClipboardMonitor.noteOwnWrite(changeCount:)`).
    @discardableResult
    func write(_ item: ClipItem, asPlainText: Bool, to pasteboard: NSPasteboard = NSPasteboard.general) -> Int {
        let items: [NSPasteboardItem]
        if asPlainText, let text = plainText(for: item) {
            items = [textItem(text)]
        } else if item.kind == .file, let fileItems = fileItems(for: item) {
            items = fileItems
        } else {
            items = richItems(for: item)
        }

        guard let first = items.first else {
            ServicesLog.paste.error("Nothing pasteable for item")
            return pasteboard.changeCount
        }
        addMarkers(to: first)
        pasteboard.clearContents()
        if !pasteboard.writeObjects(items) {
            ServicesLog.paste.error("NSPasteboard.writeObjects failed")
        }
        return pasteboard.changeCount
    }

    // MARK: - Builders

    /// Visible text for "paste as plain text" (file paths for files). nil when there is none.
    private func plainText(for item: ClipItem) -> String? {
        if let text = item.plainText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if item.kind == .file {
            let paths = fileURLs(for: item).map { $0.path }
            if !paths.isEmpty { return paths.joined(separator: "\n") }
        }
        return nil
    }

    private func textItem(_ text: String) -> NSPasteboardItem {
        let pbItem = NSPasteboardItem()
        _ = pbItem.setString(text, forType: .string)
        return pbItem
    }

    /// One pasteboard item per file (Finder-style), the first also carrying the paths as text.
    private func fileItems(for item: ClipItem) -> [NSPasteboardItem]? {
        let urls = fileURLs(for: item)
        guard !urls.isEmpty else { return nil }
        var result: [NSPasteboardItem] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            let pbItem = NSPasteboardItem()
            _ = pbItem.setString(url.absoluteString, forType: .fileURL)
            result.append(pbItem)
        }
        if let first = result.first {
            _ = first.setString(urls.map { $0.path }.joined(separator: "\n"), forType: .string)
        }
        return result
    }

    /// Every pasteable representation on a single pasteboard item, in capture order.
    private func richItems(for item: ClipItem) -> [NSPasteboardItem] {
        let payload = store.pasteboardPayload(for: item)
        let pbItem = NSPasteboardItem()
        var wroteAny = false
        var hasText = false
        for rep in payload where !rep.data.isEmpty {
            if pbItem.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti)) {
                wroteAny = true
                if ClipUTI.isText(rep.uti) { hasText = true }
            }
        }
        // Colors read from an NSColor archive, URL-only links, etc.: also offer the text.
        if !hasText, let text = item.plainText, !text.isEmpty {
            if pbItem.setString(text, forType: .string) {
                wroteAny = true
            }
        }
        return wroteAny ? [pbItem] : []
    }

    /// File URLs of a `.file` item: the full `ClipFileList` when present, else the
    /// `public.file-url` payloads, else the stored paths (shared ClipCore helper).
    private func fileURLs(for item: ClipItem) -> [URL] {
        return store.fileURLs(for: item)
    }

    private func addMarkers(to pbItem: NSPasteboardItem) {
        _ = pbItem.setString("1", forType: NSPasteboard.PasteboardType(PasteboardMarkers.ownWrite))
        if let bundleID = Bundle.main.bundleIdentifier {
            // http://nspasteboard.org — tells other clipboard tools where this came from.
            _ = pbItem.setString(bundleID, forType: NSPasteboard.PasteboardType(ClipUTI.source))
        }
    }
}
