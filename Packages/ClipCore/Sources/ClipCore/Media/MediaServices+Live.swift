import Foundation

// Owned by the extensions engineer.

extension MediaServices {
    /// Real implementations: ImageIO/CGPDF thumbnails, Vision OCR, LinkPresentation previews.
    ///
    /// Install once at app launch (both apps, NOT the share extension):
    /// `ClipStore.shared.media = .live()`
    /// then `Task { await store.enrich(item) }` after ingest fills `ClipUTI.thumbnail`,
    /// `ClipUTI.linkIcon`, `ClipUTI.linkPreviewImage` and `ocrText`.
    public static func live() -> MediaServices {
        return MediaServices(
            thumbnails: ImageIOThumbnailGenerator(),
            textRecognizer: VisionTextRecognizer(),
            linkMetadata: LinkPreviewFetcher()
        )
    }
}
