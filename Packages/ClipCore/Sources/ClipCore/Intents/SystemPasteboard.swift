import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Owned by the extensions engineer.

/// Minimal system-pasteboard bridge for App Intents (iOS: UIPasteboard, macOS: NSPasteboard).
/// The Mac clipboard monitor and paste service have their own, richer code; this is only
/// for "Save Clipboard" / "Copy Latest" run from Shortcuts.
@MainActor
public enum SystemPasteboard {

    /// Builds a draft from the current pasteboard (first item only).
    /// iOS: reading the contents may show the system "Allow Paste" prompt when run from
    /// Shortcuts; `numberOfItems` / `types` are checked first because they never prompt.
    public static func readDraft() throws -> ClipDraft {
        #if canImport(UIKit)
        let pasteboard = UIPasteboard.general
        guard pasteboard.numberOfItems > 0 else { throw ClipIntentError.emptyClipboard }
        let declared = pasteboard.types
        guard let first = pasteboard.items.first else { throw ClipIntentError.emptyClipboard }

        var orderedTypes = declared
        for key in first.keys where !orderedTypes.contains(key) {
            orderedTypes.append(key)
        }

        var payloads: [ClipDraft.Representation] = []
        var plainText: String?
        var urlText: String?
        var storedImageAsPNG = false

        for type in orderedTypes {
            guard TypeNormalizer.isStorable(TypeNormalizer.normalize(type)), let value = first[type] else { continue }
            if let data = value as? Data {
                if plainText == nil, ClipUTI.isText(type) {
                    plainText = String(data: data, encoding: .utf8)
                }
                if urlText == nil, type == ClipUTI.url {
                    urlText = String(data: data, encoding: .utf8)
                }
                if !data.isEmpty {
                    payloads.append(ClipDraft.Representation(uti: type, data: data))
                }
            } else if let string = value as? String {
                if plainText == nil, ClipUTI.isText(type) {
                    plainText = string
                }
                if urlText == nil, type == ClipUTI.url {
                    urlText = string
                }
                if !string.isEmpty {
                    payloads.append(ClipDraft.Representation(uti: type, data: Data(string.utf8)))
                }
            } else if let url = value as? URL {
                let string = url.absoluteString
                if urlText == nil {
                    urlText = string
                }
                payloads.append(ClipDraft.Representation(uti: type, data: Data(string.utf8)))
            } else if let image = value as? UIImage {
                // UIImage values are re-encoded once, labelled honestly as PNG.
                if !storedImageAsPNG, let png = image.pngData() {
                    payloads.append(ClipDraft.Representation(uti: ClipUTI.png, data: png))
                    storedImageAsPNG = true
                }
            }
        }
        var types = declared
        if storedImageAsPNG && !types.contains(ClipUTI.png) {
            types.append(ClipUTI.png)
        }
        return try makeDraft(types: types, payloads: payloads, string: plainText ?? urlText)

        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        guard let first = pasteboard.pasteboardItems?.first else { throw ClipIntentError.emptyClipboard }
        var declared = (pasteboard.types ?? []).map { $0.rawValue }
        for type in first.types where !declared.contains(type.rawValue) {
            declared.append(type.rawValue)
        }

        var payloads: [ClipDraft.Representation] = []
        for type in first.types {
            let raw = type.rawValue
            // ClipSync's own marker / private types (e.g. ClipUTI.ownWrite) are never stored.
            guard !ClipUTI.isInternal(raw) else { continue }
            guard TypeNormalizer.isStorable(TypeNormalizer.normalize(raw)) else { continue }
            if let data = first.data(forType: type), !data.isEmpty {
                payloads.append(ClipDraft.Representation(uti: raw, data: data))
            }
        }
        var text = first.string(forType: .string)
        if text == nil {
            text = first.string(forType: .URL)
        }
        if text == nil, let fileURLString = first.string(forType: .fileURL), let url = URL(string: fileURLString) {
            text = url.path
        }
        return try makeDraft(types: declared, payloads: payloads, string: text)

        #else
        throw ClipIntentError.emptyClipboard
        #endif
    }

    /// Replaces the pasteboard with one item. Text UTIs are written as strings.
    /// Returns false when there was nothing to write.
    @discardableResult
    public static func write(_ representations: [ClipDraft.Representation], plainText: String?) -> Bool {
        #if canImport(UIKit)
        var item: [String: Any] = [:]
        for rep in representations where item[rep.uti] == nil && !ClipUTI.isInternal(rep.uti) {
            if ClipUTI.isText(rep.uti), let string = String(data: rep.data, encoding: .utf8) {
                item[rep.uti] = string
            } else if rep.uti == ClipUTI.url,
                      let string = String(data: rep.data, encoding: .utf8),
                      let url = URL(string: string) {
                item[rep.uti] = url
            } else {
                item[rep.uti] = rep.data
            }
        }
        if item.isEmpty, let text = plainText, !text.isEmpty {
            item[ClipUTI.utf8PlainText] = text
        }
        guard !item.isEmpty else { return false }
        UIPasteboard.general.setItems([item], options: [:])
        return true

        #elseif canImport(AppKit)
        let item = NSPasteboardItem()
        var wrote = false
        for rep in representations where !ClipUTI.isInternal(rep.uti) {
            if item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti)) {
                wrote = true
            }
        }
        if !wrote, let text = plainText, !text.isEmpty {
            wrote = item.setString(text, forType: .string)
        }
        guard wrote else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])

        #else
        return false
        #endif
    }

    /// Pure part of `readDraft` (unit-tested): classification → draft or error.
    public static func makeDraft(types: [String], payloads: [ClipDraft.Representation], string: String?) throws -> ClipDraft {
        let classification = PasteboardTypeClassifier.classify(types: types, string: string)
        switch classification {
        case .kind(let kind):
            let draft = ClipDraft(
                kind: kind,
                plainText: string,
                representations: payloads,
                declaredTypes: types
            )
            if draft.isEmpty {
                throw ClipIntentError.emptyClipboard
            }
            return draft
        case .skip(let reason):
            switch reason {
            case .concealed, .transient, .autoGenerated, .ignoredType:
                throw ClipIntentError.sensitiveContent
            case .empty, .unsupported:
                throw ClipIntentError.emptyClipboard
            }
        }
    }
}
