import Foundation
import UIKit
import ImageIO
import ClipCore

/// Where an image's bytes are: in memory (small inline payloads) or a blob file on disk.
enum ImageSourceInput {
    case data(Data)
    case file(URL)
}

/// ImageIO downsampling. Never decodes the full-size bitmap; safe to call off the main thread.
enum ImageDownsampler {
    static func downsample(_ input: ImageSourceInput, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        switch input {
        case .data(let data):
            source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        case .file(let url):
            source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions)
        }
        guard let imageSource = source else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Process-wide memory cache of decoded thumbnails (NSCache is thread-safe and purges on memory pressure).
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Resolves where a clip's preview image lives and loads a downsampled copy off the main thread.
@MainActor
enum ThumbnailLoader {
    static func cacheKey(for item: ClipItem, maxPixelSize: Int, large: Bool) -> String {
        return "\(item.id.uuidString)#\(maxPixelSize)#\(large ? "L" : "S")"
    }

    /// Main actor: only reads model attributes and, for small inline payloads, their bytes.
    /// Blob-backed payloads are read later, off the main thread, straight from the file.
    static func sourceInput(for item: ClipItem, store: ClipStore, large: Bool) -> ImageSourceInput? {
        guard item.isAlive, let rep = item.previewImageRepresentation(large: large) else { return nil }
        if let name = rep.fileName {
            return .file(store.blobStore.fileURL(for: name))
        }
        if let data = store.data(for: rep) {
            return .data(data)
        }
        return nil
    }

    static func load(item: ClipItem, store: ClipStore, maxPixelSize: Int, large: Bool) async -> UIImage? {
        let key = cacheKey(for: item, maxPixelSize: maxPixelSize, large: large)
        if let cached = ThumbnailCache.shared.image(forKey: key) {
            return cached
        }
        guard let input = sourceInput(for: item, store: store, large: large) else { return nil }
        let size = maxPixelSize
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            return ImageDownsampler.downsample(input, maxPixelSize: size)
        }.value
        if let image = image {
            ThumbnailCache.shared.insert(image, forKey: key)
        }
        return image
    }
}
