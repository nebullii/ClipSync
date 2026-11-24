import SwiftUI
import UIKit
import ClipCore

/// ClipSync's own visual identity: a deep "tide" teal accent, soft cards,
/// and one tint per clip kind. (The asset catalog's AccentColor matches `accent`.)
enum Theme {
    static let cardCornerRadius: CGFloat = 16
    static let rowIconCornerRadius: CGFloat = 10

    /// Accent from the asset catalog (teal 700 light / teal 400 dark).
    static let accent = Color("AccentColor")

    /// Fixed, high-contrast background for the system paste control. The paste
    /// control is a secure control: it must stay clearly legible (white on dark teal).
    static let pasteControlBackground = UIColor(red: 0.059, green: 0.463, blue: 0.431, alpha: 1.0)

    static func tint(for kind: ClipKind) -> Color {
        switch kind {
        case .text: return Color(red: 0.38, green: 0.45, blue: 0.56)
        case .richText: return .indigo
        case .link: return .teal
        case .image: return .purple
        case .file: return .orange
        case .color: return .pink
        case .pdf: return .red
        }
    }

    static var groupedBackground: Color {
        return Color(uiColor: .systemGroupedBackground)
    }

    static var cardBackground: Color {
        return Color(uiColor: .secondarySystemGroupedBackground)
    }
}

extension Color {
    /// Builds a color from "#RGB", "#RRGGBB" or "#RRGGBBAA"; `fallback` when invalid.
    init(clipHex hex: String, fallback: Color = .accentColor) {
        if let parts = ColorParser.components(fromHex: hex) {
            self.init(.sRGB, red: parts.red, green: parts.green, blue: parts.blue, opacity: parts.alpha)
        } else {
            self = fallback
        }
    }
}

enum ColorMath {
    /// True when black text reads better than white on this color.
    static func prefersDarkText(onHex hex: String) -> Bool {
        guard let parts = ColorParser.components(fromHex: hex) else { return false }
        let luminance = 0.2126 * parts.red + 0.7152 * parts.green + 0.0722 * parts.blue
        if parts.alpha < 0.5 { return true }
        return luminance > 0.6
    }

    /// "#RRGGBB" for a SwiftUI color (sRGB), nil if it cannot be resolved.
    static func hexString(from color: Color) -> String? {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ value: CGFloat) -> Int {
            return max(0, min(255, Int((value * 255).rounded())))
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// "R 30 · G 144 · B 255" style description for a hex color.
    static func rgbDescription(forHex hex: String) -> String? {
        guard let parts = ColorParser.components(fromHex: hex) else { return nil }
        let red = Int((parts.red * 255).rounded())
        let green = Int((parts.green * 255).rounded())
        let blue = Int((parts.blue * 255).rounded())
        var text = "R \(red) · G \(green) · B \(blue)"
        if parts.alpha < 1 {
            text += " · A \(Int((parts.alpha * 100).rounded()))%"
        }
        return text
    }
}
