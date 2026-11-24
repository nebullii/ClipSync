import Foundation

/// The kind of a clipboard item. Stored on `ClipItem` as its raw string (`kindRaw`),
/// so `#Predicate`s must compare `kindRaw` against `kind.rawValue`.
public enum ClipKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case text
    case richText
    case link
    case image
    case file
    case color
    case pdf

    public var id: String { rawValue }

    /// English display name (UI layers may localize).
    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .color: return "Color"
        case .pdf: return "PDF"
        }
    }

    /// SF Symbol name suitable for filters and placeholders.
    public var systemImageName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        case .pdf: return "doc.richtext"
        }
    }

    /// Kinds whose identity is their plain text (used for hashing / dedup).
    public var isTextual: Bool {
        switch self {
        case .text, .richText, .link, .color: return true
        case .image, .file, .pdf: return false
        }
    }
}
