import Foundation

/// Parses color strings such as "#FFF", "#1E90FF", "#1E90FF80", "rgb(30, 144, 255)",
/// "rgba(30,144,255,0.5)". A leading "#" is required for hex so words like
/// "facade" are not mistaken for colors.
public enum ColorParser {
    /// Uppercase "#RRGGBB" or "#RRGGBBAA", or nil when the string is not a color.
    public static func normalizedHex(from string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 64 { return nil }
        if trimmed.hasPrefix("#") {
            return parseHex(String(trimmed.dropFirst()))
        }
        return parseRGB(trimmed.lowercased())
    }

    /// True when `normalizedHex(from:)` succeeds.
    public static func isColor(_ string: String) -> Bool {
        return normalizedHex(from: string) != nil
    }

    /// Components in 0...1 for a "#RGB", "#RRGGBB" or "#RRGGBBAA" string (with or without "#").
    public static func components(fromHex hex: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var body = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#") { body = String(body.dropFirst()) }
        guard let normalized = parseHex(body) else { return nil }
        let digits = Array(normalized.dropFirst())
        func byte(_ index: Int) -> Double {
            let pair = String(digits[index]) + String(digits[index + 1])
            return Double(UInt8(pair, radix: 16) ?? 0) / 255.0
        }
        let alpha = digits.count == 8 ? byte(6) : 1.0
        return (red: byte(0), green: byte(2), blue: byte(4), alpha: alpha)
    }

    // MARK: - Private

    private static func parseHex(_ body: String) -> String? {
        guard body.count == 3 || body.count == 6 || body.count == 8 else { return nil }
        guard body.allSatisfy({ $0.isHexDigit }) else { return nil }
        var expanded = body
        if body.count == 3 {
            expanded = body.map { String($0) + String($0) }.joined()
        }
        return "#" + expanded.uppercased()
    }

    private static func parseRGB(_ lower: String) -> String? {
        let hasAlpha: Bool
        let inner: String
        if lower.hasPrefix("rgba(") && lower.hasSuffix(")") {
            hasAlpha = true
            inner = String(lower.dropFirst(5).dropLast())
        } else if lower.hasPrefix("rgb(") && lower.hasSuffix(")") {
            hasAlpha = false
            inner = String(lower.dropFirst(4).dropLast())
        } else {
            return nil
        }
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (hasAlpha ? 4 : 3) else { return nil }
        var result = "#"
        for index in 0..<3 {
            guard let value = Int(parts[index]), value >= 0, value <= 255 else { return nil }
            result += hexByte(value)
        }
        if hasAlpha {
            guard let alpha = Double(parts[3]), alpha >= 0, alpha <= 1 else { return nil }
            result += hexByte(Int((alpha * 255).rounded()))
        }
        return result
    }

    private static func hexByte(_ value: Int) -> String {
        let digits: [Character] = Array("0123456789ABCDEF")
        let clamped = max(0, min(255, value))
        return String(digits[clamped / 16]) + String(digits[clamped % 16])
    }
}
