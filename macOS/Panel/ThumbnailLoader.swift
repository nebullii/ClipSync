// Owned by the Mac panel UI engineer.
//
// Image previews for cards. Rules:
//   - The main actor only picks WHICH bytes to show (a few property reads). Blob-stored
//     payloads are handed over as a file URL, so a 50 MB image is never read or
//     decoded on the main thread.
//   - Decoding/downsampling (ImageIO thumbnail API; PDF page 1 via CGPDFDocument) runs
//     on a small background OperationQueue.
//   - Results are kept in an NSCache keyed by item + source, so a thumbnail produced
//     later by ClipStore.enrich (new key) replaces the decoded original automatically.

import AppKit
import ImageIO
import CoreGraphics
import ClipCore

enum PanelThumbnailRole: String {
    /// The card body preview (image / PDF items).
    case content
    /// Site icon of a link item.
    case linkIcon
    /// Large preview image of a link item.
    case linkImage
}

/// Bytes or a file to decode. Data and URL are Sendable, so this crosses threads safely.
enum PanelThumbnailSource: Sendable {
    case imageData(Data)
    case imageFile(URL)
    case pdfData(Data)
    case pdfFile(URL)
}

// MARK: - Decoder (nonisolated, pure)

enum PanelThumbnailDecoder {
    static func decode(_ source: PanelThumbnailSource, maxPixelSize: Int) -> NSImage? {
        let cgImage: CGImage?
        switch source {
        case .imageData(let data):
            cgImage = CGImageSourceCreateWithData(data as CFData, sourceOptions())
                .flatMap { downsample($0, maxPixelSize: maxPixelSize) }
        case .imageFile(let url):
            cgImage = CGImageSourceCreateWithURL(url as CFURL, sourceOptions())
                .flatMap { downsample($0, maxPixelSize: maxPixelSize) }
        case .pdfData(let data):
            if let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) {
                cgImage = renderFirstPage(of: document, maxPixelSize: maxPixelSize)
            } else {
                cgImage = nil
            }
        case .pdfFile(let url):
            if let document = CGPDFDocument(url as CFURL) {
                cgImage = renderFirstPage(of: document, maxPixelSize: maxPixelSize)
            } else {
                cgImage = nil
            }
        }
        guard let image = cgImage else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Decodes on `queue` (never the main thread). Formed outside any actor so the
    /// operation closure is not main-actor isolated.
    static func decode(_ source: PanelThumbnailSource, maxPixelSize: Int, on queue: OperationQueue) async -> NSImage? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            queue.addOperation {
                let image = PanelThumbnailDecoder.decode(source, maxPixelSize: maxPixelSize)
                continuation.resume(returning: image)
            }
        }
    }

    private static func sourceOptions() -> CFDictionary {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        return options as CFDictionary
    }

    private static func downsample(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func renderFirstPage(of document: CGPDFDocument, maxPixelSize: Int) -> CGImage? {
        guard let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(maxPixelSize) / max(box.width, box.height)
        let width = max(1, Int(box.width * scale))
        let height = max(1, Int(box.height * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

// MARK: - Loader + cache

@MainActor
final class PanelThumbnailLoader {
    static let shared = PanelThumbnailLoader()
    static let defaultMaxPixelSize = 480

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue

    private struct Resolved {
        let representation: ClipRepresentation
        let isPDF: Bool
        let tag: String
    }

    private init() {
        let queue = OperationQueue()
        queue.name = "ClipSync.Panel.Thumbnails"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        self.queue = queue
        cache.countLimit = 400
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    private func resolve(_ item: ClipItem, role: PanelThumbnailRole) -> Resolved? {
        switch role {
        case .content:
            if let thumb = item.representation(forUTI: ClipUTI.thumbnail) {
                return Resolved(representation: thumb, isPDF: false, tag: "t")
            }
            let reps = item.pasteableRepresentations
            if let image = reps.first(where: { ClipUTI.isImage($0.uti) }) {
                return Resolved(representation: image, isPDF: false, tag: "o")
            }
            if let pdf = reps.first(where: { $0.uti == ClipUTI.pdf }) {
                return Resolved(representation: pdf, isPDF: true, tag: "p")
            }
            return nil
        case .linkIcon:
            guard let rep = item.representation(forUTI: ClipUTI.linkIcon) else { return nil }
            return Resolved(representation: rep, isPDF: false, tag: "i")
        case .linkImage:
            guard let rep = item.representation(forUTI: ClipUTI.linkPreviewImage) else { return nil }
            return Resolved(representation: rep, isPDF: false, tag: "l")
        }
    }

    /// Stable key for the bytes that would be shown, or nil when there is nothing to show.
    func cacheKey(for item: ClipItem, role: PanelThumbnailRole) -> String? {
        guard let resolved = resolve(item, role: role) else { return nil }
        let itemID: UUID = item.id
        return "\(itemID.uuidString)|\(role.rawValue)|\(resolved.tag)|\(resolved.representation.byteSize)"
    }

    func cachedImage(forKey key: String) -> NSImage? {
        return cache.object(forKey: key as NSString)
    }

    func loadImage(for item: ClipItem, role: PanelThumbnailRole, store: ClipStore,
                   maxPixelSize: Int = PanelThumbnailLoader.defaultMaxPixelSize) async -> NSImage? {
        guard let resolved = resolve(item, role: role), let key = cacheKey(for: item, role: role) else { return nil }
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let source = makeSource(resolved, store: store) else { return nil }
        let image = await decodeInBackground(source, maxPixelSize: maxPixelSize)
        if let image = image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    private func makeSource(_ resolved: Resolved, store: ClipStore) -> PanelThumbnailSource? {
        let rep = resolved.representation
        if let blobName = rep.fileName {
            let url = store.blobStore.fileURL(for: blobName)
            return resolved.isPDF ? .pdfFile(url) : .imageFile(url)
        }
        // Inline payloads are small (≤ inline threshold); reading them here is cheap.
        guard let data = store.data(for: rep) else { return nil }
        return resolved.isPDF ? .pdfData(data) : .imageData(data)
    }

    private func decodeInBackground(_ source: PanelThumbnailSource, maxPixelSize: Int) async -> NSImage? {
        return await PanelThumbnailDecoder.decode(source, maxPixelSize: maxPixelSize, on: queue)
    }
}

// MARK: - App / file icons

@MainActor
final class PanelIconCache {
    static let shared = PanelIconCache()

    private let appIcons = NSCache<NSString, NSImage>()
    private let fileIcons = NSCache<NSString, NSImage>()
    private var unknownBundleIDs = Set<String>()

    private init() {
        appIcons.countLimit = 200
        fileIcons.countLimit = 300
    }

    /// Icon of the app with this bundle ID (resolved once through NSWorkspace, cached).
    func appIcon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID = bundleID, !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let cached = appIcons.object(forKey: key) { return cached }
        if unknownBundleIDs.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            unknownBundleIDs.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        appIcons.setObject(icon, forKey: key)
        return icon
    }

    /// Finder icon of a file (generic icon for missing files).
    func fileIcon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = fileIcons.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        fileIcons.setObject(icon, forKey: key)
        return icon
    }
}

// MARK: - File lists

/// File URLs of a `.file` item, cached per item for card rendering. The format is pinned
/// in ClipCore: `store.fileURLs(for:)` reads the internal `ClipUTI.fileURLList`
/// (`ClipFileList` format, all copied files) first, then `public.file-url`, then the paths
/// in `plainText`. Items that carry file CONTENTS only (iOS share-extension file drafts)
/// return [] and the card shows the item's title instead.
@MainActor
enum PanelFileList {
    private static var cache: [String: [URL]] = [:]

    static func fileURLs(for item: ClipItem, store: ClipStore) -> [URL] {
        let itemID: UUID = item.id
        let key = "\(itemID.uuidString)|\(item.byteSize)"
        if let cached = cache[key] { return cached }

        let result = store.fileURLs(for: item)

        if cache.count > 500 { cache.removeAll() }
        cache[key] = result
        return result
    }
}
