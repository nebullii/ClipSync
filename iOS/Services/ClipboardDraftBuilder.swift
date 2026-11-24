import Foundation
import UIKit
import UniformTypeIdentifiers
import ClipCore

/// Turns the item providers delivered by `UIPasteControl` (or any paste) into `ClipDraft`s.
/// Runs off the main actor (nonisolated async), so image conversion never blocks the UI.
enum ClipboardDraftBuilder {
    struct Output {
        var drafts: [ClipDraft] = []
        var skipped: [SkipReason] = []
    }

    /// At most this many pasteboard items are saved per tap.
    static let maxItems = 10

    static func build(from providers: [NSItemProvider]) async -> Output {
        var output = Output()
        for provider in providers.prefix(maxItems) {
            switch await draft(from: provider) {
            case .draft(let draft):
                output.drafts.append(draft)
            case .skipped(let reason):
                output.skipped.append(reason)
            }
        }
        return output
    }

    private enum ProviderResult {
        case draft(ClipDraft)
        case skipped(SkipReason)
    }

    private static func draft(from provider: NSItemProvider) async -> ProviderResult {
        let types = provider.registeredTypeIdentifiers
        if let reason = PasteboardTypeClassifier.markerSkipReason(for: types) {
            return .skipped(reason)
        }

        var representations: [ClipDraft.Representation] = []

        // Plain text
        var text: String?
        if types.contains(where: { conforms($0, to: .plainText) }) {
            text = await loadString(from: provider)
        }

        // Web / mail URL (file URLs are not useful on iOS)
        var url: URL?
        if types.contains(where: { conforms($0, to: .url) && !conforms($0, to: .fileURL) }) {
            url = await loadURL(from: provider)
        }

        if let string = text, !string.isEmpty {
            representations.append(ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: Data(string.utf8)))
        }
        if let link = url, link.scheme != nil {
            representations.append(ClipDraft.Representation(uti: ClipUTI.url, data: Data(link.absoluteString.utf8)))
            if text == nil || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                text = link.absoluteString
            }
        }

        // Rich text flavors, when present
        for richType in [ClipUTI.rtf, ClipUTI.html, ClipUTI.rtfd] where types.contains(richType) {
            if let data = await loadData(from: provider, type: richType), !data.isEmpty {
                representations.append(ClipDraft.Representation(uti: richType, data: data))
            }
        }

        // Image (stored as PNG when the source is not already PNG/JPEG/HEIC)
        if let image = await loadImage(from: provider, types: types) {
            representations.append(image)
        }

        let classification = PasteboardTypeClassifier.classify(types: types, string: text)
        guard let kind = classification.kind else {
            if case .skip(let reason) = classification {
                return .skipped(reason)
            }
            return .skipped(.unsupported)
        }
        if representations.isEmpty && (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .skipped(.empty)
        }

        var draft = ClipDraft(
            kind: kind,
            plainText: text,
            representations: representations,
            declaredTypes: types,
            createdAt: Date()
        )
        // Hash off the main actor exactly like the store would (normalized representations).
        draft.contentHash = ContentHasher.hash(
            kind: kind,
            plainText: text,
            representations: TypeNormalizer.normalizeRepresentations(representations)
        )
        return .draft(draft)
    }

    // MARK: - Loading helpers

    private static func conforms(_ identifier: String, to type: UTType) -> Bool {
        guard let candidate = UTType(identifier) else { return false }
        return candidate.conforms(to: type)
    }

    private static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        // ClipCore's loader: hard timeout, resumes exactly once (a stalled provider can't hang the tap).
        return await ItemProviderLoader.loadData(from: provider, typeIdentifier: type, timeout: 20)
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        if provider.canLoadObject(ofClass: NSString.self) {
            let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let string = object as? NSString {
                        continuation.resume(returning: string as String)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let loaded = loaded {
                return loaded
            }
        }
        // Fallback: raw UTF-8 / UTF-16 bytes.
        if let data = await loadData(from: provider, type: ClipUTI.utf8PlainText),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let data = await loadData(from: provider, type: ClipUTI.utf16PlainText),
           let string = String(data: data, encoding: .utf16) {
            return string
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let nsURL = object as? NSURL {
                    continuation.resume(returning: nsURL as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadImage(from provider: NSItemProvider, types: [String]) async -> ClipDraft.Representation? {
        let imageTypes = types.filter { conforms($0, to: .image) }
        guard !imageTypes.isEmpty else { return nil }

        // Prefer PNG, then compact camera formats, then whatever is first.
        let preferredOrder = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier]
        var ordered: [String] = preferredOrder.filter { imageTypes.contains($0) }
        for type in imageTypes where !ordered.contains(type) {
            ordered.append(type)
        }

        for type in ordered {
            guard let data = await loadData(from: provider, type: type), !data.isEmpty else { continue }
            if preferredOrder.contains(type) {
                return ClipDraft.Representation(uti: type, data: data)
            }
            // TIFF / GIF / WebP / BMP ...: normalize to PNG so every app can paste it.
            if let image = UIImage(data: data), let png = image.pngData() {
                return ClipDraft.Representation(uti: ClipUTI.png, data: png)
            }
            if ClipUTI.isImage(type) {
                return ClipDraft.Representation(uti: type, data: data)
            }
        }
        return nil
    }
}
