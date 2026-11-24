import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import ClipCore

// Owned by the extensions engineer.
//
// Turns one NSItemProvider at a time into a ClipDraft. Memory rules (share extensions
// are killed around 120 MB):
//   - images are read from a temporary file with ImageIO; PNG/JPEG up to
//     `keepOriginalImageBytes` are stored as-is (never decoded); anything else is
//     downsampled straight from the file to ≤ `maxImagePixelSize` and re-encoded;
//   - files are size-checked before they are read, and skipped above the 20 MB sync cap;
//   - no OCR, thumbnails or link fetching here (the app enriches items later).

/// Result of loading one attachment.
enum ShareLoadOutcome: Sendable {
    case draft(ClipDraft)
    case skipped(String)
}

enum ShareAttachmentLoader {
    static let maxFileBytes = StoragePolicy.defaultSyncSizeCapBytes          // 20 MB
    static let keepOriginalImageBytes = 15 * 1024 * 1024
    static let maxImagePixelSize = 2560                                      // ≤ 26 MB bitmap while encoding
    static let maxTextBytes = 5 * 1024 * 1024
    static let shortTimeout: TimeInterval = 20
    static let longTimeout: TimeInterval = 60                                // iCloud files may download first

    // MARK: Dispatch

    static func load(_ provider: NSItemProvider) async -> ShareLoadOutcome {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await loadImage(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return await loadFile(provider, preferredType: UTType.pdf.identifier, kind: .pdf)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadURL(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await loadText(provider)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadFile(provider, preferredType: nil, kind: .file)
        }
        return .skipped("Unsupported item")
    }

    /// Text that came without attachments (`NSExtensionItem.attributedContentText`).
    static func textOutcome(_ text: String) -> ShareLoadOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skipped("Empty text") }
        guard text.utf8.count <= maxTextBytes else { return .skipped("Text is too long") }
        return .draft(ClipDraft.text(text))
    }

    // MARK: Text & links

    private static func loadText(_ provider: NSItemProvider) async -> ShareLoadOutcome {
        let text: String? = await ItemProviderLoader.loadItem(
            from: provider,
            typeIdentifier: UTType.plainText.identifier,
            timeout: shortTimeout,
            transform: { (item: NSSecureCoding?) -> String? in
                if let string = item as? String { return string }
                if let attributed = item as? NSAttributedString { return attributed.string }
                if let url = item as? URL {
                    if url.isFileURL {
                        return try? String(contentsOf: url, encoding: .utf8)
                    }
                    return url.absoluteString
                }
                if let data = item as? Data { return String(data: data, encoding: .utf8) }
                return nil
            }
        )
        guard let text = text else { return .skipped("Couldn't read the text") }
        return textOutcome(text)
    }

    private static func loadURL(_ provider: NSItemProvider) async -> ShareLoadOutcome {
        let urlString: String? = await ItemProviderLoader.loadItem(
            from: provider,
            typeIdentifier: UTType.url.identifier,
            timeout: shortTimeout,
            transform: { (item: NSSecureCoding?) -> String? in
                if let url = item as? URL { return url.isFileURL ? nil : url.absoluteString }
                if let string = item as? String { return string }
                if let data = item as? Data { return String(data: data, encoding: .utf8) }
                return nil
            }
        )
        guard let urlString = urlString,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Some apps vend a file through public.url; try it as a file.
            return await loadFile(provider, preferredType: nil, kind: .file)
        }
        // Classifies as .link (with a utf8 text representation); dedups with Mac copies of the same URL.
        return textOutcome(urlString)
    }

    // MARK: Images

    private static func loadImage(_ provider: NSItemProvider) async -> ShareLoadOutcome {
        let typeID = preferredTypeIdentifier(of: provider, conformingTo: .image) ?? UTType.image.identifier

        // 1) File representation: ImageIO reads from disk, nothing is fully decoded.
        let fromFile: ShareLoadOutcome? = await ItemProviderLoader.loadFile(
            from: provider,
            typeIdentifier: typeID,
            timeout: longTimeout,
            transform: { (url: URL) -> ShareLoadOutcome? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let byteCount = ShareAttachmentLoader.fileSize(of: url) ?? Int.max
                return ShareAttachmentLoader.imageOutcome(source: source, byteCount: byteCount, readOriginal: {
                    try? Data(contentsOf: url)
                })
            }
        )
        if let outcome = fromFile {
            return outcome
        }

        // 2) Object fallback (in-memory UIImage / Data / URL from apps that don't vend files).
        let fromItem: ShareLoadOutcome? = await ItemProviderLoader.loadItem(
            from: provider,
            typeIdentifier: typeID,
            timeout: shortTimeout,
            transform: { (item: NSSecureCoding?) -> ShareLoadOutcome? in
                if let url = item as? URL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let byteCount = ShareAttachmentLoader.fileSize(of: url) ?? Int.max
                    return ShareAttachmentLoader.imageOutcome(source: source, byteCount: byteCount, readOriginal: {
                        try? Data(contentsOf: url)
                    })
                }
                if let data = item as? Data, let source = CGImageSourceCreateWithData(data as CFData, nil) {
                    return ShareAttachmentLoader.imageOutcome(source: source, byteCount: data.count, readOriginal: { data })
                }
                if let image = item as? UIImage {
                    return ShareAttachmentLoader.imageOutcome(from: image)
                }
                return nil
            }
        )
        return fromItem ?? .skipped("Couldn't read the image")
    }

    /// Keeps small PNG/JPEG bytes as they are; otherwise downsamples and re-encodes.
    private static func imageOutcome(source: CGImageSource, byteCount: Int, readOriginal: () -> Data?) -> ShareLoadOutcome? {
        guard let size = ImageEncoding.pixelSize(of: source) else { return nil }
        let container = ImageEncoding.typeIdentifier(of: source) ?? ""
        let isPortable = container == ClipUTI.png || container == ClipUTI.jpeg
        let longest = max(size.width, size.height)

        if isPortable && byteCount <= keepOriginalImageBytes && longest <= maxImagePixelSize * 2 {
            if let original = readOriginal(), !original.isEmpty {
                return .draft(imageDraft(uti: container, data: original))
            }
        }

        var encoded: (uti: String, data: Data)?
        autoreleasepool {
            if let image = ImageEncoding.downsampledImage(source: source, maxPixelSize: maxImagePixelSize) {
                encoded = ImageEncoding.compactEncoding(of: image)
            }
        }
        guard let result = encoded else { return nil }
        return .draft(imageDraft(uti: result.uti, data: result.data))
    }

    private static func imageOutcome(from image: UIImage) -> ShareLoadOutcome? {
        // Already decoded by the host app; re-encode once, then downsample through ImageIO.
        guard let jpeg = image.jpegData(compressionQuality: 0.9),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return imageOutcome(source: source, byteCount: jpeg.count, readOriginal: { jpeg })
    }

    private static func imageDraft(uti: String, data: Data) -> ClipDraft {
        var draft = ClipDraft(
            kind: .image,
            representations: [ClipDraft.Representation(uti: uti, data: data)],
            declaredTypes: [uti]
        )
        draft.contentHash = ContentHasher.hash(draft)   // hash big payloads off the main actor
        return draft
    }

    // MARK: Files

    private static func loadFile(_ provider: NSItemProvider, preferredType: String?, kind: ClipKind) async -> ShareLoadOutcome {
        let typeID = preferredType
            ?? preferredTypeIdentifier(of: provider, conformingTo: .data)
            ?? provider.registeredTypeIdentifiers.first
            ?? UTType.data.identifier
        let suggestedName = provider.suggestedName

        let fromFile: ShareLoadOutcome? = await ItemProviderLoader.loadFile(
            from: provider,
            typeIdentifier: typeID,
            timeout: longTimeout,
            transform: { (url: URL) -> ShareLoadOutcome? in
                return ShareAttachmentLoader.fileOutcome(at: url, typeIdentifier: typeID, suggestedName: suggestedName, kind: kind)
            }
        )
        if let outcome = fromFile {
            return outcome
        }

        // Fallback: the provider hands us a file URL object (e.g. public.file-url).
        let fromURL: ShareLoadOutcome? = await ItemProviderLoader.loadItem(
            from: provider,
            typeIdentifier: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                ? UTType.fileURL.identifier : typeID,
            timeout: longTimeout,
            transform: { (item: NSSecureCoding?) -> ShareLoadOutcome? in
                guard let url = item as? URL, url.isFileURL else { return nil }
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                return ShareAttachmentLoader.fileOutcome(at: url, typeIdentifier: nil, suggestedName: suggestedName, kind: kind)
            }
        )
        return fromURL ?? .skipped("Couldn't read the file")
    }

    private static func fileOutcome(at url: URL, typeIdentifier: String?, suggestedName: String?, kind: ClipKind) -> ShareLoadOutcome {
        let name = displayName(suggestedName: suggestedName, url: url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            return .skipped("\u{201C}\(name)\u{201D} is a folder")
        }
        if let size = values?.fileSize, size > maxFileBytes {
            return .skipped("\u{201C}\(name)\u{201D} is larger than 20 MB")
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return .skipped("Couldn't read \u{201C}\(name)\u{201D}")
        }
        guard data.count <= maxFileBytes else {
            return .skipped("\u{201C}\(name)\u{201D} is larger than 20 MB")
        }
        let uti = storableUTI(typeIdentifier: typeIdentifier, url: url, kind: kind)
        var draft = ClipDraft(
            kind: kind,
            title: name,
            representations: [ClipDraft.Representation(uti: uti, data: data)],
            declaredTypes: [uti]
        )
        draft.contentHash = ContentHasher.hash(draft)
        return .draft(draft)
    }

    // MARK: Helpers

    private static func preferredTypeIdentifier(of provider: NSItemProvider, conformingTo type: UTType) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            if let candidate = UTType(identifier), candidate.conforms(to: type) {
                return identifier
            }
        }
        return nil
    }

    /// A UTI the store will keep (dynamic "dyn.*" types are dropped by TypeNormalizer).
    private static func storableUTI(typeIdentifier: String?, url: URL, kind: ClipKind) -> String {
        if kind == .pdf { return ClipUTI.pdf }
        if let identifier = typeIdentifier, !identifier.hasPrefix("dyn."),
           identifier != UTType.fileURL.identifier, identifier != UTType.url.identifier {
            return identifier
        }
        if let fromExtension = UTType(filenameExtension: url.pathExtension), !fromExtension.isDynamic {
            return fromExtension.identifier
        }
        return UTType.data.identifier
    }

    private static func displayName(suggestedName: String?, url: URL) -> String {
        let fileName = url.lastPathComponent
        guard let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty else {
            return fileName
        }
        // suggestedName often lacks the extension; keep the real one.
        let ext = url.pathExtension
        if !ext.isEmpty && (suggested as NSString).pathExtension.isEmpty {
            return suggested + "." + ext
        }
        return suggested
    }

    private static func fileSize(of url: URL) -> Int? {
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
