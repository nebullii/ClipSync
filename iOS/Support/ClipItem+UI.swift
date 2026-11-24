import Foundation
import SwiftData
import ClipCore

/// iOS-only presentation helpers over `ClipItem`. Read-only; all mutations go through `ClipStore`.
extension ClipItem {
    /// False once the item was deleted (by us, retention, or a sync merge). Check before
    /// reading attributes in views that may outlive the item.
    var isAlive: Bool {
        return modelContext != nil && !isDeleted
    }

    /// Plain text suitable for "Copy as plain text" / sharing (nil when there is none).
    var visibleText: String? {
        guard let text = plainText else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return text
    }

    var hasPlainText: Bool {
        return visibleText != nil
    }

    /// A short preview of the text (never the whole multi-MB string).
    func previewText(maxCharacters: Int = 400) -> String {
        guard let text = plainText else { return displayTitle }
        if text.count <= maxCharacters { return text }
        return String(text.prefix(maxCharacters)) + "…"
    }

    /// Web/mail URL for link items.
    var linkURL: URL? {
        guard kind == .link, let text = visibleText else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    var linkHost: String? {
        guard let url = linkURL else { return nil }
        if let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.scheme
    }

    /// Representation to draw as an image preview, if any.
    /// - Parameter large: prefer the link preview image over the icon for links.
    func previewImageRepresentation(large: Bool) -> ClipRepresentation? {
        switch kind {
        case .image:
            if !large, let thumb = representation(forUTI: ClipUTI.thumbnail) {
                return thumb
            }
            if let original = pasteableRepresentations.first(where: { ClipUTI.isImage($0.uti) }) {
                return original
            }
            return representation(forUTI: ClipUTI.thumbnail)
        case .pdf:
            return representation(forUTI: ClipUTI.thumbnail)
        case .link:
            if large, let image = representation(forUTI: ClipUTI.linkPreviewImage) {
                return image
            }
            return representation(forUTI: ClipUTI.linkIcon)
        case .text, .richText, .file, .color:
            return nil
        }
    }

    /// Display names of the files of a `.file` item (from its plain-text paths / file URLs).
    var fileNames: [String] {
        guard let text = plainText else { return [] }
        var names: [String] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("file://"), let url = URL(string: line) {
                names.append(url.lastPathComponent)
            } else {
                let name = (line as NSString).lastPathComponent
                names.append(name.isEmpty ? line : name)
            }
        }
        return names
    }

    /// Heuristic: render as code (monospaced) when it looks like source code.
    var looksLikeCode: Bool {
        guard kind == .text, let text = plainText else { return false }
        let sample = String(text.prefix(2_000))
        guard sample.contains("\n") else { return false }
        let markers = ["{", "}", ";", "=>", "func ", "let ", "var ", "def ", "return", "</", "import "]
        var hits = 0
        for marker in markers where sample.contains(marker) {
            hits += 1
        }
        return hits >= 2
    }

    /// "Link · Safari · 5 min ago"
    var metaLine: String {
        var parts: [String] = []
        if let host = linkHost {
            parts.append(host)
        } else {
            parts.append(kind.displayName)
        }
        if let app = sourceAppName, !app.isEmpty {
            parts.append(app)
        }
        parts.append(lastUsedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    var byteSizeDescription: String {
        return ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    /// VoiceOver label for rows and cards.
    var accessibilityDescription: String {
        var parts: [String] = []
        if isPinned {
            parts.append("Pinned")
        }
        parts.append(kind.displayName)
        switch kind {
        case .color:
            parts.append(colorHex ?? displayTitle)
        case .image:
            if let ocr = ocrText, !ocr.isEmpty {
                parts.append(ClipText.derivedTitle(from: ocr, maxLength: 120) ?? "")
            }
        case .file:
            parts.append(fileNames.prefix(3).joined(separator: ", "))
        default:
            parts.append(displayTitle)
        }
        if let app = sourceAppName, !app.isEmpty {
            parts.append("from \(app)")
        }
        parts.append(lastUsedAt.formatted(.relative(presentation: .named)))
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func isMember(of board: Pinboard) -> Bool {
        return (pinboards ?? []).contains { $0.id == board.id }
    }
}
