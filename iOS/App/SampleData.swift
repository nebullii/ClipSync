import Foundation
import UIKit
import ClipCore

/// Deterministic sample clips for `-uitest-seed` (in-memory store only).
@MainActor
enum SampleData {
    static func seed(into store: ClipStore) {
        let now = Date()
        // Oldest first, so the last ingested is the newest (row 0 = "Meeting notes").
        var drafts: [ClipDraft] = []

        drafts.append(.text("ClipSync keeps your clipboard history in sync between your Mac and iPhone.",
                            sourceAppBundleID: "com.apple.mobilenotes", sourceAppName: "Notes"))
        drafts.append(fileDraft())
        drafts.append(.text("rgb(245, 158, 11)", sourceAppBundleID: "com.figma.Desktop", sourceAppName: "Figma"))
        drafts.append(.text("hello@example.com", sourceAppBundleID: "com.apple.mobilemail", sourceAppName: "Mail"))
        drafts.append(.text("https://developer.apple.com/documentation/swiftui",
                            sourceAppBundleID: "com.apple.mobilesafari", sourceAppName: "Safari"))
        drafts.append(richTextDraft())
        drafts.append(.text("1 Infinite Loop\nCupertino, CA 95014", sourceAppBundleID: "com.apple.Maps", sourceAppName: "Maps"))
        drafts.append(imageDraft())
        drafts.append(.text(codeSample, sourceAppBundleID: "com.apple.dt.Xcode", sourceAppName: "Xcode"))
        drafts.append(.text("#14B8A6", sourceAppBundleID: "com.figma.Desktop", sourceAppName: "Figma"))
        drafts.append(.text("https://www.swift.org/blog/", sourceAppBundleID: "com.apple.mobilesafari", sourceAppName: "Safari"))
        drafts.append(.text("Meeting notes: ship the iOS beta on Friday, then collect feedback from the first ten testers.",
                            sourceAppBundleID: "com.apple.mobilenotes", sourceAppName: "Notes"))

        var items: [ClipItem] = []
        let count = drafts.count
        for (index, original) in drafts.enumerated() {
            var draft = original
            draft.createdAt = now.addingTimeInterval(-Double(count - index) * 900)
            draft.deviceName = index % 2 == 0 ? "MacBook Pro" : "iPhone"
            if let item = store.ingest(draft) {
                items.append(item)
            }
        }

        // items[0] is the oldest.
        if items.count >= 12 {
            store.pin(items[8])            // code snippet
            store.pin(items[0])            // intro text

            let work = store.createPinboard(name: "Work", colorHex: ClipConstants.pinboardPalette[0])
            store.add(items[11], to: work)  // meeting notes
            store.add(items[4], to: work)   // SwiftUI docs link
            store.add(items[3], to: work)   // email

            let design = store.createPinboard(name: "Design", colorHex: ClipConstants.pinboardPalette[5])
            store.add(items[9], to: design) // teal color
            store.add(items[2], to: design) // amber color
            store.add(items[7], to: design) // image
        }
    }

    private static let codeSample = """
    struct Greeting: View {
        let name: String

        var body: some View {
            Text("Hello, \\(name)!")
                .font(.title)
        }
    }
    """

    private static func fileDraft() -> ClipDraft {
        let path = "/Users/sam/Documents/Quarterly Report.pdf"
        let fileURL = URL(fileURLWithPath: path)
        return ClipDraft(
            kind: .file,
            plainText: path,
            sourceAppBundleID: "com.apple.finder",
            sourceAppName: "Finder",
            representations: [
                ClipDraft.Representation(uti: ClipUTI.fileURL, data: Data(fileURL.absoluteString.utf8)),
                ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: Data(path.utf8))
            ],
            declaredTypes: [ClipUTI.fileURL, ClipUTI.utf8PlainText]
        )
    }

    private static func richTextDraft() -> ClipDraft {
        let text = "Release checklist: bump the version, archive, upload to TestFlight."
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: UIFont.systemFont(ofSize: 15)]
        )
        attributed.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 15), range: NSRange(location: 0, length: 18))
        var reps: [ClipDraft.Representation] = []
        if let rtf = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            reps.append(ClipDraft.Representation(uti: ClipUTI.rtf, data: rtf))
        }
        reps.append(ClipDraft.Representation(uti: ClipUTI.utf8PlainText, data: Data(text.utf8)))
        return ClipDraft(
            kind: .richText,
            plainText: text,
            sourceAppBundleID: "com.apple.Pages",
            sourceAppName: "Pages",
            representations: reps,
            declaredTypes: [ClipUTI.rtf, ClipUTI.utf8PlainText]
        )
    }

    private static func imageDraft() -> ClipDraft {
        let size = CGSize(width: 640, height: 400)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let png = renderer.pngData { context in
            let cg = context.cgContext
            let colors = [
                UIColor(red: 0.06, green: 0.46, blue: 0.43, alpha: 1).cgColor,
                UIColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: CGRect(x: 60, y: 70, width: 300, height: 190), cornerRadius: 24).fill()
            UIColor.white.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: CGRect(x: 280, y: 140, width: 300, height: 190), cornerRadius: 24).fill()
            let title = NSAttributedString(
                string: "Sample image",
                attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 34),
                    .foregroundColor: UIColor(red: 0.06, green: 0.46, blue: 0.43, alpha: 1)
                ]
            )
            title.draw(at: CGPoint(x: 84, y: 100))
        }
        return ClipDraft(
            kind: .image,
            sourceAppBundleID: "com.apple.mobileslideshow",
            sourceAppName: "Photos",
            representations: [ClipDraft.Representation(uti: ClipUTI.png, data: png)],
            declaredTypes: [ClipUTI.png]
        )
    }
}
