import AppKit
import ClipCore

/// Per-representation and per-snapshot size caps applied while reading the pasteboard.
struct PasteboardReadLimits: Sendable, Equatable {
    /// Plain text larger than this (UTF-8) is not captured at all.
    var maxTextBytes: Int = 32 * 1024 * 1024
    /// RTF / HTML.
    var maxRichTextBytes: Int = 32 * 1024 * 1024
    /// Images, PDF, RTFD.
    var maxLargeBytes: Int = 200 * 1024 * 1024
    /// public.url and the NSColor archive.
    var maxSmallBytes: Int = 256 * 1024
    /// App-private / unknown types (kept so pasting back into the same app keeps fidelity).
    var maxOtherTypeBytes: Int = 2 * 1024 * 1024
    var maxOtherTypes: Int = 12
    /// Whole snapshot. Matches the store's ingest cap.
    var maxTotalBytes: Int = StoragePolicy.defaultMaxIngestBytes
    /// Files copied at once (Finder selection). Only URLs are stored, never file contents.
    var maxFileURLs: Int = 50_000
    /// At most this many image flavors per item (e.g. PNG + TIFF).
    var maxImageRepresentations: Int = 2
    /// When PNG exists, a TIFF larger than this is dropped (TIFFs of screenshots are huge).
    var maxRedundantTIFFBytes: Int = 8 * 1024 * 1024
}

/// What the main actor knew when it scheduled a read.
struct PasteboardCaptureContext: Sendable, Equatable {
    let changeCount: Int
    let sourceAppBundleID: String?
    let sourceAppName: String?
}

/// Result of reading the pasteboard off the main thread.
enum PasteboardReadOutcome: Sendable {
    /// Ready to ingest (content hash already computed).
    case draft(ClipDraft)
    /// Nothing to record; the string is a log-safe reason (never content).
    case skipped(String)
    /// The pasteboard changed while reading; a newer change will be read instead.
    case stale
}

/// Builds a `ClipDraft` from `NSPasteboard.general`.
///
/// `read(_:limits:)` is synchronous and blocking (pasteboard IPC, lazily provided
/// data, Universal Clipboard downloads), so call it on a background queue only.
/// It never touches main-actor state.
enum PasteboardReader {
    /// Type names that are never read: lazily promised files (reading them can make the
    /// source app write files), legacy duplicates, dynamic types and the remote marker.
    static func shouldSkipReading(_ rawType: String) -> Bool {
        let lower = rawType.lowercased()
        if lower.contains("promise") { return true }
        if lower.hasPrefix("dyn.") { return true }
        if lower.hasPrefix("corepasteboardflavortype") { return true }
        if rawType == "com.apple.is-remote-clipboard" { return true }
        if rawType == PasteboardMarkers.ownWrite { return true }
        if rawType == ClipUTI.source { return true }
        return false
    }

    static func read(_ context: PasteboardCaptureContext, limits: PasteboardReadLimits) -> PasteboardReadOutcome {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == context.changeCount else { return .stale }

        // Every declared type name (first item's order, then other items' extras).
        let topTypes: [String] = (pasteboard.types ?? []).map { $0.rawValue }
        var declared = topTypes
        var declaredSet = Set(topTypes)
        if let items = pasteboard.pasteboardItems {
            for item in items.prefix(20) {
                for type in item.types where !declaredSet.contains(type.rawValue) {
                    declared.append(type.rawValue)
                    declaredSet.insert(type.rawValue)
                }
            }
        }

        if declaredSet.contains(PasteboardMarkers.ownWrite) {
            return .skipped("own write")
        }
        if let reason = PasteboardTypeClassifier.markerSkipReason(for: declared) {
            return .skipped("marker: \(reason.rawValue)")
        }

        let normalizedSet = Set(TypeNormalizer.normalize(declared))
        var string: String? = nil
        if !normalizedSet.isDisjoint(with: ClipUTI.textTypes) {
            if let value = pasteboard.string(forType: .string) {
                if value.utf8.count > limits.maxTextBytes {
                    return .skipped("text too large")
                }
                string = value
            }
        }

        let classification = PasteboardTypeClassifier.classify(types: declared, string: string)
        guard let kind = classification.kind else {
            if case .skip(let reason) = classification {
                return .skipped("classified: \(reason.rawValue)")
            }
            return .skipped("classified")
        }

        let outcome: PasteboardReadOutcome
        if kind == .file {
            outcome = readFiles(pasteboard: pasteboard, context: context, declared: declared, limits: limits)
        } else {
            outcome = readContent(
                pasteboard: pasteboard,
                kind: kind,
                string: string,
                context: context,
                topTypes: topTypes,
                declared: declared,
                limits: limits
            )
        }

        // Data read while the pasteboard changed may mix two copies: discard it.
        guard pasteboard.changeCount == context.changeCount else { return .stale }
        return outcome
    }

    // MARK: - Files

    private static func readFiles(
        pasteboard: NSPasteboard,
        context: PasteboardCaptureContext,
        declared: [String],
        limits: PasteboardReadLimits
    ) -> PasteboardReadOutcome {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        var urls: [URL] = []
        var seenPaths = Set<String>()
        urls.reserveCapacity(min(max(objects.count, 1), limits.maxFileURLs))
        for object in objects {
            guard urls.count < limits.maxFileURLs else { break }
            guard let url = object as? URL, url.isFileURL else { continue }
            let pathURL = (url as NSURL).filePathURL ?? url
            if seenPaths.insert(pathURL.standardizedFileURL.path).inserted {
                urls.append(pathURL)
            }
        }
        // A multi-file copy (Finder) is one pasteboard item per file, each with its own
        // public.file-url. Read every item explicitly as well, so no file is lost when
        // readObjects returns fewer objects than there are items.
        for item in pasteboard.pasteboardItems ?? [] {
            guard urls.count < limits.maxFileURLs else { break }
            guard let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL else { continue }
            let pathURL = (url as NSURL).filePathURL ?? url
            if seenPaths.insert(pathURL.standardizedFileURL.path).inserted {
                urls.append(pathURL)
            }
        }
        guard let first = urls.first else { return .skipped("no file URLs") }

        let paths = urls.map { $0.path }.joined(separator: "\n")
        let title: String
        if urls.count == 1 {
            title = first.lastPathComponent
        } else {
            title = "\(first.lastPathComponent) + \(urls.count - 1) more"
        }

        var reps: [ClipDraft.Representation] = [
            ClipDraft.Representation(uti: ClipUTI.fileURL, data: Data(first.absoluteString.utf8))
        ]
        if urls.count > 1 {
            reps.append(ClipDraft.Representation(uti: ClipUTI.fileURLList, data: ClipFileList.encode(urls)))
        }

        var draft = ClipDraft(
            kind: .file,
            plainText: paths,
            title: title,
            sourceAppBundleID: context.sourceAppBundleID,
            sourceAppName: context.sourceAppName,
            representations: reps,
            declaredTypes: declared,
            createdAt: Date()
        )
        draft.contentHash = ContentHasher.hash(draft)
        return .draft(draft)
    }

    // MARK: - Everything else

    private enum Category {
        case text, rich, large, image, small, other
    }

    private static func category(of uti: String) -> Category {
        if ClipUTI.isText(uti) { return .text }
        if ClipUTI.isImage(uti) { return .image }
        if uti == ClipUTI.pdf || uti == ClipUTI.rtfd || uti == "com.apple.rtfd" { return .large }
        if uti == ClipUTI.rtf || uti == ClipUTI.html { return .rich }
        if uti == ClipUTI.url || uti == ClipUTI.color { return .small }
        return .other
    }

    private static func readContent(
        pasteboard: NSPasteboard,
        kind: ClipKind,
        string: String?,
        context: PasteboardCaptureContext,
        topTypes: [String],
        declared: [String],
        limits: PasteboardReadLimits
    ) -> PasteboardReadOutcome {
        let normalizedTop = Set(TypeNormalizer.normalize(topTypes))
        let hasPNG = normalizedTop.contains(ClipUTI.png)

        var reps: [ClipDraft.Representation] = []
        var seen = Set<String>()
        var total = 0
        var otherCount = 0
        var imageCount = 0
        var wroteText = false
        var colorHexFromArchive: String? = nil

        for raw in topTypes {
            if shouldSkipReading(raw) { continue }
            let uti = TypeNormalizer.normalize(raw)
            guard TypeNormalizer.isStorable(uti), !ClipUTI.isInternal(uti) else { continue }
            guard !seen.contains(uti) else { continue }
            seen.insert(uti)

            let group = category(of: uti)
            if group == .text {
                // One UTF-8 flavor is enough; the system converts for readers of other text types.
                if !wroteText, let text = string, !text.isEmpty {
                    let data = Data(text.utf8)
                    if total + data.count <= limits.maxTotalBytes {
                        reps.append(ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: data))
                        total += data.count
                    }
                }
                wroteText = true
                continue
            }

            let cap: Int
            switch group {
            case .text: cap = limits.maxTextBytes
            case .rich: cap = limits.maxRichTextBytes
            case .large, .image: cap = limits.maxLargeBytes
            case .small: cap = limits.maxSmallBytes
            case .other: cap = limits.maxOtherTypeBytes
            }
            if group == .image && imageCount >= limits.maxImageRepresentations { continue }
            if group == .other && otherCount >= limits.maxOtherTypes { continue }

            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(raw)), !data.isEmpty else { continue }
            if data.count > cap { continue }
            if group == .image && uti == ClipUTI.tiff && hasPNG && data.count > limits.maxRedundantTIFFBytes { continue }
            if total + data.count > limits.maxTotalBytes { continue }

            if uti == ClipUTI.color, colorHexFromArchive == nil {
                colorHexFromArchive = colorHex(fromPasteboard: pasteboard)
            }

            reps.append(ClipDraft.Representation(uti: uti, data: data))
            total += data.count
            if group == .image { imageCount += 1 }
            if group == .other { otherCount += 1 }
        }

        // Visible text: the string, else the URL, else the color.
        var plainText = string
        if (plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plainText = nil
            if kind == .link, let urlString = pasteboard.string(forType: .URL) {
                plainText = urlString
            } else if kind == .color, let hex = colorHexFromArchive {
                plainText = hex
            } else if kind == .richText,
                      let rtf = reps.first(where: { $0.uti == ClipUTI.rtf })?.data,
                      rtf.count <= limits.maxRichTextBytes,
                      let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                // RTF parsing is thread-safe (unlike HTML, which needs WebKit on the main thread).
                let text = attributed.string
                plainText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
        }

        switch kind {
        case .image:
            guard reps.contains(where: { ClipUTI.isImage($0.uti) }) else { return .skipped("image unreadable or too large") }
        case .pdf:
            guard reps.contains(where: { $0.uti == ClipUTI.pdf }) else { return .skipped("pdf unreadable or too large") }
        case .text, .richText, .link, .color, .file:
            break
        }

        var draft = ClipDraft(
            kind: kind,
            plainText: plainText,
            sourceAppBundleID: context.sourceAppBundleID,
            sourceAppName: context.sourceAppName,
            representations: reps,
            declaredTypes: declared,
            createdAt: Date()
        )
        if draft.isEmpty { return .skipped("empty") }
        draft.contentHash = ContentHasher.hash(draft)
        return .draft(draft)
    }

    // MARK: - Colors

    private static func colorHex(fromPasteboard pasteboard: NSPasteboard) -> String? {
        guard let color = NSColor(from: pasteboard) else { return nil }
        return hexString(for: color)
    }

    /// "#RRGGBB", or "#RRGGBBAA" when not opaque. nil for pattern/catalog colors without RGB.
    static func hexString(for color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int {
            let value = Int((component * 255.0).rounded())
            return max(0, min(255, value))
        }
        let red = byte(rgb.redComponent)
        let green = byte(rgb.greenComponent)
        let blue = byte(rgb.blueComponent)
        let alpha = byte(rgb.alphaComponent)
        if alpha < 255 {
            return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
