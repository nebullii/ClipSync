// Owned by the Mac panel UI engineer.
//
// Quick Look (Space) and drag-out support: turns a ClipItem into file URLs.
// Images/PDFs are exported to a temp folder (blob files are copied — an APFS clone, so
// no 50 MB read on the main thread), files use their own URLs, text becomes .txt/.rtf/
// .html, colors a small HTML swatch.

import AppKit
import Quartz
import UniformTypeIdentifiers
import ClipCore

/// QLPreviewPanel data source. Plain NSObject (no actor state besides the URL list).
final class PanelQuickLookDataSource: NSObject, QLPreviewPanelDataSource {
    var urls: [URL] = []

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

@MainActor
enum PanelQuickLook {
    static var isPanelVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return QLPreviewPanel.shared()?.isVisible ?? false
    }

    static var temporaryDirectory: URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent("ClipSyncPreview", isDirectory: true)
    }

    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static func ensureTemporaryDirectory() -> URL? {
        let directory = temporaryDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    // MARK: Preview URLs

    static func previewURLs(for item: ClipItem, store: ClipStore) -> [URL] {
        switch item.kind {
        case .file:
            let existing = PanelFileList.fileURLs(for: item, store: store)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty { return existing }
            // File CONTENTS without a URL (iOS share-extension file drafts): preview the bytes.
            if let rep = item.pasteableRepresentations.first(where: { $0.uti != ClipUTI.fileURL }),
               let url = export(rep, of: item, store: store) {
                return [url]
            }
            return textURL(for: item).map { [$0] } ?? []
        case .image:
            if let rep = item.pasteableRepresentations.first(where: { ClipUTI.isImage($0.uti) }),
               let url = export(rep, of: item, store: store) {
                return [url]
            }
            return []
        case .pdf:
            if let rep = item.representation(forUTI: ClipUTI.pdf), let url = export(rep, of: item, store: store) {
                return [url]
            }
            return []
        case .richText:
            if let rep = item.representation(forUTI: ClipUTI.rtf), let url = export(rep, of: item, store: store) {
                return [url]
            }
            if let rep = item.representation(forUTI: ClipUTI.html), let url = export(rep, of: item, store: store) {
                return [url]
            }
            return textURL(for: item).map { [$0] } ?? []
        case .color:
            return colorSwatchURL(for: item).map { [$0] } ?? []
        case .text, .link:
            return textURL(for: item).map { [$0] } ?? []
        }
    }

    /// Writes (or reuses) a temp file holding one representation's bytes.
    static func export(_ rep: ClipRepresentation, of item: ClipItem, store: ClipStore) -> URL? {
        guard let directory = ensureTemporaryDirectory() else { return nil }
        let fileExtension = UTType(rep.uti)?.preferredFilenameExtension ?? "data"
        let itemID: UUID = item.id
        let url = directory.appendingPathComponent("\(itemID.uuidString)-\(rep.sortIndex).\(fileExtension)")
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            return url   // representation bytes never change, so a previous export is valid
        }
        if let blobName = rep.fileName {
            let source = store.blobStore.fileURL(for: blobName)
            if (try? manager.copyItem(at: source, to: url)) != nil {
                return url
            }
        }
        guard let data = store.data(for: rep) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func textURL(for item: ClipItem) -> URL? {
        guard let directory = ensureTemporaryDirectory() else { return nil }
        let text = item.plainText ?? item.displayTitle
        let itemID: UUID = item.id
        let url = directory.appendingPathComponent("\(itemID.uuidString).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func colorSwatchURL(for item: ClipItem) -> URL? {
        guard let hex = item.colorHex, let directory = ensureTemporaryDirectory() else {
            return textURL(for: item)
        }
        let foreground = PanelPalette.prefersDarkForeground(hex: hex) ? "#000000" : "#FFFFFF"
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head>
        <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
        background:\(hex);color:\(foreground);font:600 44px -apple-system,Helvetica,sans-serif;">\(hex)</body></html>
        """
        let itemID: UUID = item.id
        let url = directory.appendingPathComponent("\(itemID.uuidString)-color.html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: Drag out

    /// Item provider for dragging a card into other apps: text as a string, links as a
    /// URL, files as the (first) file URL, images/PDFs as an exported temp file.
    static func dragProvider(for item: ClipItem, store: ClipStore) -> NSItemProvider {
        switch item.kind {
        case .text, .richText, .color:
            if let text = item.plainText, !text.isEmpty {
                return NSItemProvider(object: text as NSString)
            }
        case .link:
            let raw = (item.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: raw) {
                return NSItemProvider(object: url as NSURL)
            }
        case .file:
            if let url = PanelFileList.fileURLs(for: item, store: store).first,
               let provider = NSItemProvider(contentsOf: url) {
                return provider
            }
            if let url = previewURLs(for: item, store: store).first,
               let provider = NSItemProvider(contentsOf: url) {
                return provider
            }
        case .image, .pdf:
            if let url = previewURLs(for: item, store: store).first,
               let provider = NSItemProvider(contentsOf: url) {
                return provider
            }
        }
        return NSItemProvider(object: item.displayTitle as NSString)
    }
}
