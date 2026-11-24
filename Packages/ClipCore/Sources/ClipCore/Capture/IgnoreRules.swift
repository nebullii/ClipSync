import Foundation

/// Source apps whose copies are never recorded.
///
/// Entries are bundle IDs compared case-insensitively. An entry ending in ".*" is a
/// prefix rule ("com.1password.*" matches "com.1password.1password").
/// Persisted by `AppSettings.ignoreRules` (JSON).
public struct IgnoreRules: Codable, Sendable, Equatable {
    /// Preloaded password-manager list.
    public static let defaultBundleIDs: [String] = [
        "com.1password.1password",
        "com.1password.*",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4",
        "com.agilebits.*",
        "com.bitwarden.desktop",
        "com.8bit.bitwarden",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc"
    ]

    /// Bundle IDs (or prefix rules) added by the user.
    public var userBundleIDs: [String]
    /// When false, only `userBundleIDs` apply.
    public var includeDefaults: Bool

    public init(userBundleIDs: [String] = [], includeDefaults: Bool = true) {
        self.userBundleIDs = userBundleIDs
        self.includeDefaults = includeDefaults
    }

    /// The rules actually applied.
    public var effectiveBundleIDs: [String] {
        return includeDefaults ? IgnoreRules.defaultBundleIDs + userBundleIDs : userBundleIDs
    }

    /// True when copies from `bundleID` must be dropped. nil/empty bundle IDs are never ignored.
    public func shouldIgnore(bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return false }
        let candidate = IgnoreRules.normalize(bundleID)
        if candidate.isEmpty { return false }
        for rule in effectiveBundleIDs {
            let normalizedRule = IgnoreRules.normalize(rule)
            if normalizedRule.isEmpty { continue }
            if normalizedRule.hasSuffix(".*") {
                let prefix = String(normalizedRule.dropLast(1)) // keep the trailing "."
                if candidate.hasPrefix(prefix) { return true }
            } else if candidate == normalizedRule {
                return true
            }
        }
        return false
    }

    /// Adds a user rule (no-op if already present, case-insensitive).
    public mutating func add(_ bundleID: String) {
        let normalized = IgnoreRules.normalize(bundleID)
        guard !normalized.isEmpty else { return }
        if userBundleIDs.contains(where: { IgnoreRules.normalize($0) == normalized }) { return }
        userBundleIDs.append(bundleID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes a user rule (case-insensitive). Default rules cannot be removed individually.
    public mutating func remove(_ bundleID: String) {
        let normalized = IgnoreRules.normalize(bundleID)
        userBundleIDs.removeAll { IgnoreRules.normalize($0) == normalized }
    }

    /// Trimmed + lowercased.
    public static func normalize(_ bundleID: String) -> String {
        return bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
