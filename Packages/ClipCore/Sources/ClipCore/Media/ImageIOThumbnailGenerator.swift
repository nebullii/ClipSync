import Foundation
import CoreGraphics
import ImageIO

// Owned by the extensions engineer. Cross-platform (macOS 14 / iOS 17): CoreGraphics + ImageIO only.

/// Thumbnails for image payloads (ImageIO downsampling, never a full decode) and for
/// PDFs (first page rendered with CoreGraphics `CGPDFDocument`).
///
/// The protocol methods are nonisolated `async`, so callers on the main actor
/// (`ClipStore.enrich`) hop off the main thread automatically while the work runs.
public struct ImageIOThumbnailGenerator: ThumbnailGenerating {
    public init() {}

    public func thumbnailPNG(for data: Data, uti: String, maxPixelSize: Int) async -> Data? {
        guard let image = ImageIOThumbnailGenerator.makeThumbnail(for: data, uti: uti, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return ImageEncoding.pngData(from: image)
    }

    public func thumbnailImage(for data: Data, uti: String, maxPixelSize: Int) async -> CGImage? {
        return ImageIOThumbnailGenerator.makeThumbnail(for: data, uti: uti, maxPixelSize: maxPixelSize)
    }

    /// Synchronous core (any thread). Longest side of the result is at most `maxPixelSize`.
    public static func makeThumbnail(for data: Data, uti: String, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, !data.isEmpty else { return nil }
        if isPDF(data: data, uti: uti) {
            return pdfThumbnail(from: data, maxPixelSize: maxPixelSize)
        }
        return ImageEncoding.downsampledImage(from: data, maxPixelSize: maxPixelSize)
    }

    /// True for the PDF UTI or for data starting with "%PDF".
    static func isPDF(data: Data, uti: String) -> Bool {
        if uti == ClipUTI.pdf { return true }
        let magic: [UInt8] = [0x25, 0x50, 0x44, 0x46] // "%PDF"
        return data.count >= 4 && Array(data.prefix(4)) == magic
    }

    /// Renders page 1 of a PDF on white so its longest side is `maxPixelSize` pixels.
    public static func pdfThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return nil }
        if !document.isUnlocked {
            guard document.unlockWithPassword("") else { return nil }
        }
        guard document.numberOfPages > 0, let page = document.page(at: 1) else { return nil }

        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
        let isSideways = angle == 90 || angle == 270
        let pageWidth = isSideways ? box.height : box.width
        let pageHeight = isSideways ? box.width : box.height

        let scale = CGFloat(maxPixelSize) / max(pageWidth, pageHeight)
        let width = max(1, min(maxPixelSize, Int((pageWidth * scale).rounded())))
        let height = max(1, min(maxPixelSize, Int((pageHeight * scale).rounded())))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / pageWidth, y: CGFloat(height) / pageHeight)
        // Target rect equals the (rotated) page size, so this transform only handles
        // rotation and the crop-box origin (getDrawingTransform never scales up).
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

/// ImageIO helpers shared by thumbnails, OCR, link previews and the share extension.
public enum ImageEncoding {
    /// Decodes at most `maxPixelSize` on the longest side straight from the compressed
    /// bytes (EXIF orientation applied). Never decodes the full-size bitmap first.
    public static func downsampledImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, sourceOptions()) else {
            return nil
        }
        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    /// Same, reading from a file (the file is not loaded into memory).
    public static func downsampledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions()) else { return nil }
        return downsampledImage(source: source, maxPixelSize: maxPixelSize)
    }

    public static func downsampledImage(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel size of the first image without decoding it (nil when unreadable).
    public static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Container type of the image data (e.g. "public.png"), or nil.
    public static func typeIdentifier(of source: CGImageSource) -> String? {
        guard let type = CGImageSourceGetType(source) else { return nil }
        return type as String
    }

    public static func pngData(from image: CGImage) -> Data? {
        return encode(image, type: ClipUTI.png, properties: nil)
    }

    /// `quality` 0...1.
    public static func jpegData(from image: CGImage, quality: Double = 0.85) -> Data? {
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        return encode(image, type: ClipUTI.jpeg, properties: properties)
    }

    /// PNG when the image has alpha, else JPEG. Returns (uti, data).
    public static func compactEncoding(of image: CGImage, jpegQuality: Double = 0.85) -> (uti: String, data: Data)? {
        if hasAlpha(image) {
            guard let png = pngData(from: image) else { return nil }
            return (ClipUTI.png, png)
        }
        guard let jpeg = jpegData(from: image, quality: jpegQuality) else { return nil }
        return (ClipUTI.jpeg, jpeg)
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    /// Re-encodes arbitrary image bytes as a PNG no larger than `maxPixelSize` (icons).
    public static func normalizedPNG(from data: Data, maxPixelSize: Int) -> Data? {
        guard let image = downsampledImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        return pngData(from: image)
    }

    /// Re-encodes arbitrary image bytes compactly (JPEG unless alpha) at most `maxPixelSize`.
    public static func normalizedCompact(from data: Data, maxPixelSize: Int) -> Data? {
        guard let image = downsampledImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        return compactEncoding(of: image)?.data
    }

    private static func sourceOptions() -> CFDictionary {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        return options as CFDictionary
    }

    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any]?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties.map { $0 as CFDictionary })
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
