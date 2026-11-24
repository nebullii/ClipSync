import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import ClipCore

// Owned by the extensions engineer.

final class MediaTests: XCTestCase {

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int, opaque: Bool = true) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: alpha.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return context.makeImage()
    }

    private func makePNG(width: Int, height: Int) -> Data? {
        guard let image = makeImage(width: width, height: height) else { return nil }
        return ImageEncoding.pngData(from: image)
    }

    /// One-page US-letter PDF with a filled rectangle.
    private func makeOnePagePDF() -> Data? {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 72, y: 72, width: 200, height: 300))
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    /// Black text on white, drawn with CoreText (available on macOS and iOS).
    private func makeTextImage(_ text: String) -> Data? {
        let width = 1400
        let height = 260
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): black
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return ImageEncoding.pngData(from: image)
    }

    private func size(ofEncoded data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return ImageEncoding.pixelSize(of: source)
    }

    // MARK: - Thumbnails

    func testImageThumbnailRespectsMaxPixelSize() async throws {
        let png = try XCTUnwrap(makePNG(width: 2000, height: 1000))
        let generator = ImageIOThumbnailGenerator()

        let maybeImage = await generator.thumbnailImage(for: png, uti: ClipUTI.png, maxPixelSize: 256)
        let image = try XCTUnwrap(maybeImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 256)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(Double(image.height), 128, accuracy: 1)

        let maybePNG = await generator.thumbnailPNG(for: png, uti: ClipUTI.png, maxPixelSize: 300)
        let thumbPNG = try XCTUnwrap(maybePNG)
        let decoded = try XCTUnwrap(size(ofEncoded: thumbPNG))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 300)
        XCTAssertLessThan(thumbPNG.count, png.count)
    }

    func testImageThumbnailOfGarbageIsNil() async {
        let generator = ImageIOThumbnailGenerator()
        let png = await generator.thumbnailPNG(for: Data("not an image".utf8), uti: ClipUTI.png, maxPixelSize: 128)
        XCTAssertNil(png)
        let empty = await generator.thumbnailImage(for: Data(), uti: ClipUTI.png, maxPixelSize: 128)
        XCTAssertNil(empty)
    }

    func testPDFThumbnailFromGeneratedOnePagePDF() async throws {
        let pdf = try XCTUnwrap(makeOnePagePDF())
        XCTAssertTrue(ImageIOThumbnailGenerator.isPDF(data: pdf, uti: "public.data"))
        let generator = ImageIOThumbnailGenerator()

        let maybeImage = await generator.thumbnailImage(for: pdf, uti: ClipUTI.pdf, maxPixelSize: 300)
        let image = try XCTUnwrap(maybeImage)
        XCTAssertEqual(image.height, 300)                       // portrait: height is the long side
        XCTAssertEqual(Double(image.width), 300.0 * 612.0 / 792.0, accuracy: 1.5)

        let maybePNG = await generator.thumbnailPNG(for: pdf, uti: ClipUTI.pdf, maxPixelSize: 200)
        let png = try XCTUnwrap(maybePNG)
        let decoded = try XCTUnwrap(size(ofEncoded: png))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 200)
    }

    func testCompactEncodingPicksJPEGForOpaqueAndPNGForAlpha() throws {
        let opaque = try XCTUnwrap(makeImage(width: 64, height: 64, opaque: true))
        let translucent = try XCTUnwrap(makeImage(width: 64, height: 64, opaque: false))
        XCTAssertEqual(ImageEncoding.compactEncoding(of: opaque)?.uti, ClipUTI.jpeg)
        XCTAssertEqual(ImageEncoding.compactEncoding(of: translucent)?.uti, ClipUTI.png)
    }

    // MARK: - OCR

    func testOCRRecognizesRenderedText() async throws {
        let png = try XCTUnwrap(makeTextImage("CLIPSYNC 2026"))
        let recognizer = VisionTextRecognizer(timeout: 60)
        guard let text = await recognizer.recognizeText(in: png) else {
            throw XCTSkip("Vision text recognition is unavailable in this test host.")
        }
        if text.isEmpty {
            throw XCTSkip("Vision returned no text in this test host (no recognition model available?).")
        }
        let folded = text.uppercased().replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(folded.contains("CLIPSYNC"), "OCR result was: \(text)")
    }

    func testOCROfGarbageDataIsNil() async {
        let recognizer = VisionTextRecognizer()
        let result = await recognizer.recognizeText(in: Data("definitely not an image".utf8))
        XCTAssertNil(result)
        let empty = await recognizer.recognizeText(in: Data())
        XCTAssertNil(empty)
    }

    // MARK: - Link previews (no network)

    func testLinkFetcherOnlyAcceptsHTTPAndHTTPS() throws {
        XCTAssertTrue(LinkPreviewFetcher.isFetchable(try XCTUnwrap(URL(string: "https://example.com/a"))))
        XCTAssertTrue(LinkPreviewFetcher.isFetchable(try XCTUnwrap(URL(string: "HTTP://example.com"))))
        XCTAssertFalse(LinkPreviewFetcher.isFetchable(try XCTUnwrap(URL(string: "file:///etc/hosts"))))
        XCTAssertFalse(LinkPreviewFetcher.isFetchable(try XCTUnwrap(URL(string: "mailto:a@example.com"))))
        XCTAssertFalse(LinkPreviewFetcher.isFetchable(try XCTUnwrap(URL(string: "ftp://example.com/file"))))
        XCTAssertFalse(LinkPreviewFetcher.isFetchable(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(LinkPreviewFetcher.isFetchable(try XCTUnwrap(URL(string: "https:relative"))))
    }

    func testLinkFetcherRejectsNonHTTPWithoutNetwork() async throws {
        let fetcher = LinkPreviewFetcher(timeout: 10)
        let started = Date()
        let fileURL = try XCTUnwrap(URL(string: "file:///etc/hosts"))
        let mailURL = try XCTUnwrap(URL(string: "mailto:a@example.com"))
        let fileResult = await fetcher.fetchMetadata(for: fileURL)
        let mailResult = await fetcher.fetchMetadata(for: mailURL)
        XCTAssertNil(fileResult)
        XCTAssertNil(mailResult)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "non-http URLs must return immediately")
    }

    // MARK: - Store integration

    @MainActor
    func testEnrichStoresThumbnailForImageItem() async throws {
        let store = ClipStore.makeShared(inMemory: true)
        store.media = MediaServices(
            thumbnails: ImageIOThumbnailGenerator(),
            textRecognizer: NoopTextRecognizer(),
            linkMetadata: NoopLinkMetadataFetcher()
        )
        let png = try XCTUnwrap(makePNG(width: 1600, height: 900))
        let draft = ClipDraft(
            kind: .image,
            representations: [ClipDraft.Representation(uti: ClipUTI.png, data: png)],
            declaredTypes: [ClipUTI.png]
        )
        let item = try XCTUnwrap(store.ingest(draft))
        await store.enrich(item)

        let thumb = try XCTUnwrap(store.data(for: item, uti: ClipUTI.thumbnail))
        let decoded = try XCTUnwrap(size(ofEncoded: thumb))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 512)
        XCTAssertFalse(store.pasteboardPayload(for: item).contains { $0.uti == ClipUTI.thumbnail })
    }

    func testLiveServicesUseRealImplementations() {
        let live = MediaServices.live()
        XCTAssertTrue(live.thumbnails is ImageIOThumbnailGenerator)
        XCTAssertTrue(live.textRecognizer is VisionTextRecognizer)
        XCTAssertTrue(live.linkMetadata is LinkPreviewFetcher)
    }
}
