import Foundation
import CryptoKit

/// SHA-256 content identity used for dedup.
///
/// Textual kinds (text, richText, link, color) hash only their normalized plain text,
/// so the same words copied as plain or rich text dedup to one item.
/// Other kinds hash the kind plus every non-internal representation (sorted by UTI)
/// plus the normalized text.
public enum ContentHasher {
    /// Line endings unified to "\n", leading/trailing whitespace trimmed.
    public static func normalizeText(_ text: String) -> String {
        return ClipText.normalizeLineEndings(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sha256Hex(_ data: Data) -> String {
        return hex(SHA256.hash(data: data))
    }

    public static func sha256Hex(_ string: String) -> String {
        return sha256Hex(Data(string.utf8))
    }

    /// The dedup hash for a piece of content.
    public static func hash(kind: ClipKind, plainText: String?, representations: [ClipDraft.Representation]) -> String {
        let text = normalizeText(plainText ?? "")
        if kind.isTextual && !text.isEmpty {
            return sha256Hex("text:" + text)
        }
        var hasher = SHA256()
        hasher.update(data: Data(("kind:" + kind.rawValue + "\n").utf8))
        let sorted = representations
            .filter { !ClipUTI.isInternal($0.uti) }
            .sorted { $0.uti < $1.uti }
        for rep in sorted {
            hasher.update(data: Data(("uti:" + rep.uti + ":" + String(rep.data.count) + "\n").utf8))
            hasher.update(data: rep.data)
        }
        if !text.isEmpty {
            hasher.update(data: Data(("text:" + text).utf8))
        }
        return hex(hasher.finalize())
    }

    /// Hash for a draft (normalizes the draft's representations first, like the store does).
    public static func hash(_ draft: ClipDraft) -> String {
        return hash(
            kind: draft.kind,
            plainText: draft.plainText,
            representations: TypeNormalizer.normalizeRepresentations(draft.representations)
        )
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits: [Character] = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(64)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }
}
