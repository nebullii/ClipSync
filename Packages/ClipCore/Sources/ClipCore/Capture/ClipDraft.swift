import Foundation

/// A captured clipboard snapshot, built by platform code from NSPasteboard /
/// UIPasteboard / share-extension input, then handed to `ClipStore.ingest(_:)`.
/// Plain value type: safe to build on a background queue and send to the main actor.
public struct ClipDraft: Sendable, Equatable {
    /// One pasteboard flavor: a UTI and its bytes.
    public struct Representation: Sendable, Equatable {
        public var uti: String
        public var data: Data

        public init(uti: String, data: Data) {
            self.uti = uti
            self.data = data
        }
    }

    public var kind: ClipKind
    /// Plain-text rendering (string content, URL string, file paths, color string...).
    public var plainText: String?
    /// Optional explicit title; ClipStore derives one from `plainText` when nil.
    public var title: String?
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    /// Payload flavors in preference order. Marker/dyn types are filtered by the store.
    public var representations: [Representation]
    /// Every type name that was on the pasteboard (including marker types that carry
    /// no data). The store rejects the draft if any is a concealed/transient/auto marker.
    public var declaredTypes: [String]
    public var createdAt: Date
    public var deviceName: String?
    /// Optional precomputed `ContentHasher.hash(...)` (lets capture code hash big
    /// images off the main actor). When nil the store computes it.
    public var contentHash: String?

    public init(
        kind: ClipKind,
        plainText: String? = nil,
        title: String? = nil,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        representations: [Representation] = [],
        declaredTypes: [String] = [],
        createdAt: Date = Date(),
        deviceName: String? = nil,
        contentHash: String? = nil
    ) {
        self.kind = kind
        self.plainText = plainText
        self.title = title
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.representations = representations
        self.declaredTypes = declaredTypes
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.contentHash = contentHash
    }

    /// Convenience: a plain-text draft carrying a public.utf8-plain-text representation.
    /// The kind is classified (text / link / color) from the string.
    public static func text(
        _ text: String,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil,
        createdAt: Date = Date()
    ) -> ClipDraft {
        let classification = PasteboardTypeClassifier.classify(types: [ClipUTI.utf8PlainText], string: text)
        return ClipDraft(
            kind: classification.kind ?? .text,
            plainText: text,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            representations: [Representation(uti: ClipUTI.utf8PlainText, data: Data(text.utf8))],
            declaredTypes: [ClipUTI.utf8PlainText],
            createdAt: createdAt
        )
    }

    /// Sum of representation byte counts, or the UTF-8 size of `plainText` when there are none.
    public var totalByteSize: Int {
        let repBytes = representations.reduce(0) { $0 + $1.data.count }
        if repBytes > 0 { return repBytes }
        return plainText?.utf8.count ?? 0
    }

    /// True when there is neither visible text nor any non-empty representation.
    public var isEmpty: Bool {
        let text = (plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty && !representations.contains { !$0.data.isEmpty }
    }
}
