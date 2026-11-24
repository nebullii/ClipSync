import Foundation
import SwiftData

/// Case- and diacritic-insensitive, multi-token AND search over
/// title, plainText, ocrText and sourceAppName.
///
/// Strategy (designed for ~20,000 items): every `ClipItem` stores a pre-folded
/// `searchText`. The store pushes the FIRST token into a simple `#Predicate`
/// (`searchText.localizedStandardContains(token)`) so SQLite narrows the set, then
/// applies the remaining tokens in memory with `matches(_:tokens:)`.
public enum SearchEngine {
    /// Max characters of `plainText` / `ocrText` copied into `searchText`.
    public static let maxIndexedCharacters = 20_000

    /// Lowercased, diacritic- and width-folded text ("Café" → "cafe").
    public static func normalize(_ text: String) -> String {
        return text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    /// Normalized, de-duplicated, whitespace-separated query tokens.
    public static func tokens(from query: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in normalize(query).split(whereSeparator: { $0.isWhitespace }) {
            let token = String(part)
            if !token.isEmpty && seen.insert(token).inserted {
                result.append(token)
            }
        }
        return result
    }

    /// Builds the folded text stored in `ClipItem.searchText`.
    public static func makeSearchText(title: String?, plainText: String?, ocrText: String?, sourceAppName: String?) -> String {
        var parts: [String] = []
        if let title = title, !title.isEmpty { parts.append(title) }
        if let plainText = plainText, !plainText.isEmpty { parts.append(String(plainText.prefix(maxIndexedCharacters))) }
        if let ocrText = ocrText, !ocrText.isEmpty { parts.append(String(ocrText.prefix(maxIndexedCharacters))) }
        if let sourceAppName = sourceAppName, !sourceAppName.isEmpty { parts.append(sourceAppName) }
        return normalize(parts.joined(separator: "\n"))
    }

    /// True when the folded `searchText` contains every (already normalized) token.
    public static func matches(searchText: String, tokens: [String]) -> Bool {
        for token in tokens where !searchText.contains(token) {
            return false
        }
        return true
    }

    /// True when the item matches every token (tokens must come from `tokens(from:)`).
    public static func matches(_ item: ClipItem, tokens: [String]) -> Bool {
        if tokens.isEmpty { return true }
        var haystack = item.searchText
        if haystack.isEmpty {
            haystack = makeSearchText(
                title: item.title,
                plainText: item.plainText,
                ocrText: item.ocrText,
                sourceAppName: item.sourceAppName
            )
        }
        return matches(searchText: haystack, tokens: tokens)
    }

    /// In-memory filter (order preserved). Empty query returns `items` unchanged.
    public static func filter(_ items: [ClipItem], query: String) -> [ClipItem] {
        let queryTokens = tokens(from: query)
        if queryTokens.isEmpty { return items }
        return items.filter { matches($0, tokens: queryTokens) }
    }

    /// A deliberately simple SwiftData predicate usable with `FetchDescriptor` or `@Query`.
    /// - Parameters:
    ///   - kind: restrict to one kind (nil = all)
    ///   - pinnedOnly: only `isPinned == true` items
    ///   - firstToken: one already-normalized token (nil/empty = no text filter).
    ///     Apply remaining tokens in memory with `matches(_:tokens:)`.
    public static func predicate(kind: ClipKind? = nil, pinnedOnly: Bool = false, firstToken: String? = nil) -> Predicate<ClipItem> {
        let filterByKind = kind != nil
        let kindRaw = kind?.rawValue ?? ""
        let token = firstToken ?? ""
        let filterByToken = !token.isEmpty
        let onlyPinned = pinnedOnly
        return #Predicate<ClipItem> { item in
            (filterByKind == false || item.kindRaw == kindRaw)
                && (onlyPinned == false || item.isPinned == true)
                && (filterByToken == false || item.searchText.localizedStandardContains(token))
        }
    }

    /// Multi-kind restriction, applied IN MEMORY after a fetch (a `Set.contains` over
    /// `kindRaw` inside the combined `#Predicate` above is not worth the compile/runtime
    /// risk for a set of at most 7 raw strings). nil = no restriction.
    /// For `@Query` users: fetch with `predicate(kind: nil, ...)` and filter the results
    /// with `matches(_:kinds:)`; `ClipStore.fetchItems` does this for you and keeps paging exact.
    public static func matches(_ item: ClipItem, kinds: Set<ClipKind>?) -> Bool {
        guard let kinds = kinds else { return true }
        return kinds.contains(item.kind)
    }

    /// The single kind to push into the SQL predicate for a (`kind`, `kinds`) pair, so a
    /// one-element `kinds` set still pages in SQLite. nil = no SQL kind restriction.
    public static func sqlKind(kind: ClipKind?, kinds: Set<ClipKind>?) -> ClipKind? {
        if let kind = kind { return kind }
        if let kinds = kinds, kinds.count == 1 { return kinds.first }
        return nil
    }

    /// Convenience for `@Query`: predicate built from a raw query string (first token only).
    public static func predicate(kind: ClipKind?, pinnedOnly: Bool, query: String) -> Predicate<ClipItem> {
        return predicate(kind: kind, pinnedOnly: pinnedOnly, firstToken: tokens(from: query).first)
    }
}
