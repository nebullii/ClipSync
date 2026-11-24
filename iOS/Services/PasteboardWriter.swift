import Foundation
import UIKit
import UniformTypeIdentifiers
import ClipCore

/// Writes a clip back to `UIPasteboard.general` with every pasteable representation:
/// text as `String`, links as `URL`, images / rich text as their original bytes.
@MainActor
enum PasteboardWriter {
    /// Returns false when the item has nothing that can be put on the pasteboard.
    @discardableResult
    static func write(_ item: ClipItem, store: ClipStore, plainTextOnly: Bool) -> Bool {
        guard item.isAlive else { return false }
        let entry: [String: Any]
        if plainTextOnly {
            entry = plainTextEntry(for: item, store: store)
        } else {
            entry = fullEntry(for: item, store: store)
        }
        guard !entry.isEmpty else { return false }
        UIPasteboard.general.setItems([entry], options: [:])
        return true
    }

    /// The item's plain text, from `plainText` or a stored text representation.
    static func plainText(for item: ClipItem, store: ClipStore) -> String? {
        if let text = item.visibleText {
            return text
        }
        let candidates = [ClipUTI.utf8PlainText, ClipUTI.plainText, ClipUTI.text]
        for uti in candidates {
            if let data = store.data(for: item, uti: uti), let text = String(data: data, encoding: .utf8) {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        if let data = store.data(for: item, uti: ClipUTI.utf16PlainText), let text = String(data: data, encoding: .utf16) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func plainTextEntry(for item: ClipItem, store: ClipStore) -> [String: Any] {
        guard let text = plainText(for: item, store: store) else { return [:] }
        return [UTType.utf8PlainText.identifier: text]
    }

    private static func fullEntry(for item: ClipItem, store: ClipStore) -> [String: Any] {
        var entry: [String: Any] = [:]
        var imagePayload: (uti: String, data: Data)?

        for rep in store.pasteboardPayload(for: item) {
            let uti = rep.uti
            if ClipUTI.isText(uti) {
                continue // added once below as a String
            }
            if uti == ClipUTI.url {
                if let string = String(data: rep.data, encoding: .utf8),
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme != nil {
                    entry[UTType.url.identifier] = url
                }
                continue
            }
            if uti == ClipUTI.fileURL || uti == ClipUTI.color || uti == ClipUTI.source {
                continue // Mac file paths / archived NSColor are meaningless to iOS apps
            }
            if ClipUTI.isImage(uti) && imagePayload == nil {
                imagePayload = (uti, rep.data)
            }
            if entry[uti] == nil {
                entry[uti] = rep.data
            }
        }

        // Make sure image consumers that only read PNG/JPEG still get an image.
        if let payload = imagePayload,
           entry[UTType.png.identifier] == nil,
           entry[UTType.jpeg.identifier] == nil,
           let image = UIImage(data: payload.data),
           let png = image.pngData() {
            entry[UTType.png.identifier] = png
        }

        if let text = plainText(for: item, store: store) {
            entry[UTType.utf8PlainText.identifier] = text
            if item.kind == .link, entry[UTType.url.identifier] == nil {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), url.scheme != nil {
                    entry[UTType.url.identifier] = url
                }
            }
        }
        return entry
    }
}
