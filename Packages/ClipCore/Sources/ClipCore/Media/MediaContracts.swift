import Foundation
import CoreGraphics

// CONTRACT — owned by the extensions engineer, who adds the live implementations
// in this folder (see docs/API.md, "Media"). ClipStore only depends on the
// protocols and the no-op defaults below, so ClipCore compiles without them.
//
// Implementations must be platform-guarded (`#if canImport(...)`) where needed and
// must not import AppKit/UIKit unless wrapped in `#if canImport(AppKit)` / `#if canImport(UIKit)`.

/// Generates small preview images for image / PDF payloads.
public protocol ThumbnailGenerating: Sendable {
    /// PNG thumbnail whose longest side is at most `maxPixelSize`, or nil if unsupported.
    func thumbnailPNG(for data: Data, uti: String, maxPixelSize: Int) async -> Data?
    /// Same as a CGImage (for direct display), or nil if unsupported.
    func thumbnailImage(for data: Data, uti: String, maxPixelSize: Int) async -> CGImage?
}

/// On-device OCR (Vision).
public protocol TextRecognizing: Sendable {
    /// Recognized text. Return "" when the image has no text, nil when OCR failed/unavailable.
    func recognizeText(in imageData: Data) async -> String?
}

/// Link preview metadata (title + icon), e.g. via LPMetadataProvider.
public struct LinkMetadata: Sendable, Equatable {
    public var title: String?
    /// PNG/JPEG bytes of the site icon.
    public var iconData: Data?
    /// PNG/JPEG bytes of the preview image.
    public var imageData: Data?

    public init(title: String? = nil, iconData: Data? = nil, imageData: Data? = nil) {
        self.title = title
        self.iconData = iconData
        self.imageData = imageData
    }
}

public protocol LinkMetadataFetching: Sendable {
    /// Metadata for `url`, or nil on failure / timeout.
    func fetchMetadata(for url: URL) async -> LinkMetadata?
}

/// Bundle of media services injected into `ClipStore.media`.
public struct MediaServices: Sendable {
    public var thumbnails: any ThumbnailGenerating
    public var textRecognizer: any TextRecognizing
    public var linkMetadata: any LinkMetadataFetching

    public init(
        thumbnails: any ThumbnailGenerating,
        textRecognizer: any TextRecognizing,
        linkMetadata: any LinkMetadataFetching
    ) {
        self.thumbnails = thumbnails
        self.textRecognizer = textRecognizer
        self.linkMetadata = linkMetadata
    }

    /// Does nothing; every call returns nil. The default for `ClipStore.media`.
    public static var noop: MediaServices {
        return MediaServices(
            thumbnails: NoopThumbnailGenerator(),
            textRecognizer: NoopTextRecognizer(),
            linkMetadata: NoopLinkMetadataFetcher()
        )
    }
}

public struct NoopThumbnailGenerator: ThumbnailGenerating {
    public init() {}
    public func thumbnailPNG(for data: Data, uti: String, maxPixelSize: Int) async -> Data? { return nil }
    public func thumbnailImage(for data: Data, uti: String, maxPixelSize: Int) async -> CGImage? { return nil }
}

public struct NoopTextRecognizer: TextRecognizing {
    public init() {}
    public func recognizeText(in imageData: Data) async -> String? { return nil }
}

public struct NoopLinkMetadataFetcher: LinkMetadataFetching {
    public init() {}
    public func fetchMetadata(for url: URL) async -> LinkMetadata? { return nil }
}
