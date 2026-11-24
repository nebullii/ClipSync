// Owned by the Mac panel UI engineer.
//
// ClipSync's own visual vocabulary for the panel: per-kind header tints, color helpers
// and display formatting. (Interaction model inspired by bottom-strip clipboard
// managers; colors, layout and iconography are ClipSync's own.)

import SwiftUI
import AppKit
import ClipCore

enum PanelMetrics {
    static let cardWidth: CGFloat = 220
    static let cardHeight: CGFloat = 200
    static let cardCornerRadius: CGFloat = 14
    static let headerHeight: CGFloat = 42
    static let cardSpacing: CGFloat = 14
    static let topBarHeight: CGFloat = 30
}

struct PanelNamedColor: Identifiable {
    let name: String
    let hex: String
    var id: String { return hex }
}

enum PanelPalette {
    /// Header tint per kind ("ClipSync ink" palette). Color items use their own color.
    static func tint(for kind: ClipKind) -> Color {
        switch kind {
        case .text: return color(hex: "#5B5BD6")      // indigo ink
        case .richText: return color(hex: "#0F9488")  // teal
        case .link: return color(hex: "#2563EB")      // blue
        case .image: return color(hex: "#DB2777")     // magenta
        case .file: return color(hex: "#D97706")      // amber
        case .color: return color(hex: "#6B7280")     // replaced by the swatch color
        case .pdf: return color(hex: "#DC2626")       // red
        }
    }

    static func color(hex: String) -> Color {
        guard let components = ColorParser.components(fromHex: hex) else { return Color.gray }
        return Color(.sRGB, red: components.red, green: components.green, blue: components.blue, opacity: components.alpha)
    }

    /// Relative luminance check: true when black text reads better on this color.
    static func prefersDarkForeground(hex: String) -> Bool {
        guard let c = ColorParser.components(fromHex: hex) else { return false }
        let luminance = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        return luminance > 0.62 || c.alpha < 0.4
    }

    /// The shared pinboard palette with human names for menus.
    static var pinboardColors: [PanelNamedColor] {
        let names = ["Blue", "Green", "Yellow", "Orange", "Red", "Purple", "Pink", "Gray"]
        var result: [PanelNamedColor] = []
        for (index, hex) in ClipConstants.pinboardPalette.enumerated() {
            let name = index < names.count ? names[index] : hex
            result.append(PanelNamedColor(name: name, hex: hex))
        }
        return result
    }
}

enum PanelFormat {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relativeTime(_ date: Date, now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "Just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func byteCount(_ bytes: Int) -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func characterCount(_ text: String) -> String {
        // utf8.count is O(1) for native strings; avoid an O(n) character walk on huge texts.
        let utf8Count = text.utf8.count
        if utf8Count > 200_000 { return byteCount(utf8Count) }
        let count = text.count
        return count == 1 ? "1 character" : "\(count.formatted()) characters"
    }

    static func host(of urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { return String(host.dropFirst(4)) }
        return host
    }
}
