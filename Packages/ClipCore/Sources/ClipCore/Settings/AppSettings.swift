import Foundation
import Combine

/// User preferences shared by every target, persisted in
/// `UserDefaults(suiteName: group.com.thingbits.clipsync) ?? .standard`
/// (macOS: the suite is used only when the app is signed with the App Group).
///
/// Every property writes through to UserDefaults on change.
@MainActor
public final class AppSettings: ObservableObject {
    /// UserDefaults keys (public so platform code can observe them if needed).
    public enum Keys {
        public static let retention = "clipsync.retention"
        public static let capturePaused = "clipsync.capturePaused"
        public static let cloudSyncEnabled = "clipsync.cloudSyncEnabled"
        public static let ignoreRules = "clipsync.ignoreRules"
        public static let plainTextByDefault = "clipsync.plainTextByDefault"
        public static let launchAtLogin = "clipsync.launchAtLogin"
        public static let maxHistoryCount = "clipsync.maxHistoryCount"
        public static let hasCompletedOnboarding = "clipsync.hasCompletedOnboarding"
    }

    public static let defaultRetention: RetentionPolicy = .month
    public static let defaultMaxHistoryCount = 10_000

    private static var sharedInstance: AppSettings?

    /// The process-wide instance (App Group defaults), unless replaced with `setShared(_:)`.
    /// (Was a `static let`; now a lazily created computed property — same call sites.)
    public static var shared: AppSettings {
        if let settings = sharedInstance {
            return settings
        }
        let settings = AppSettings()
        sharedInstance = settings
        return settings
    }

    /// Replaces the instance returned by `shared` (mirrors `ClipStore.setShared`).
    /// Call at launch BEFORE anything reads `AppSettings.shared` / `ClipStore.shared`,
    /// e.g. with `AppSettings.ephemeral()` in UI-test mode.
    public static func setShared(_ settings: AppSettings) {
        sharedInstance = settings
    }

    /// Settings backed by an isolated UserDefaults suite that is wiped first, so nothing
    /// from (or to) the real user's settings leaks in or out (UI tests, previews).
    /// The suite is cleared again on every call; it is never the App Group suite.
    public static func ephemeral(suiteName: String = "com.thingbits.clipsync.ephemeral") -> AppSettings {
        let fallbackName = "com.thingbits.clipsync.ephemeral"
        var name = suiteName.isEmpty ? fallbackName : suiteName
        var suite = UserDefaults(suiteName: name)
        if suite == nil {
            // nil only for reserved names (the app's own bundle ID, NSGlobalDomain).
            name = fallbackName
            suite = UserDefaults(suiteName: name)
        }
        guard let defaults = suite else {
            // Unreachable in practice. Never fall back to .standard: wiping it would
            // destroy the real user's settings.
            fatalError("ClipCore: cannot create the ephemeral UserDefaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        for key in AppSettings.allKeys { defaults.removeObject(forKey: key) }
        return AppSettings(defaults: defaults)
    }

    /// Every key this class persists.
    public static var allKeys: [String] {
        return [
            Keys.retention, Keys.capturePaused, Keys.cloudSyncEnabled, Keys.ignoreRules,
            Keys.plainTextByDefault, Keys.launchAtLogin, Keys.maxHistoryCount, Keys.hasCompletedOnboarding
        ]
    }

    public let defaults: UserDefaults

    /// How long unpinned history is kept.
    @Published public var retention: RetentionPolicy {
        didSet { defaults.set(retention.rawValue, forKey: Keys.retention) }
    }

    /// When true the Mac clipboard monitor must not record anything.
    /// (Checked by the monitor, not by `ClipStore.ingest`, so manual saves still work.)
    @Published public var capturePaused: Bool {
        didSet { defaults.set(capturePaused, forKey: Keys.capturePaused) }
    }

    /// iCloud sync opt-in. Takes effect at next launch (the ModelContainer is created once).
    @Published public var cloudSyncEnabled: Bool {
        didSet { defaults.set(cloudSyncEnabled, forKey: Keys.cloudSyncEnabled) }
    }

    /// Ignore list (defaults + user entries), persisted as JSON.
    @Published public var ignoreRules: IgnoreRules {
        didSet { AppSettings.save(ignoreRules, to: defaults) }
    }

    /// Paste as plain text by default (Mac panel: ⇧↩ always pastes as plain text).
    @Published public var plainTextByDefault: Bool {
        didSet { defaults.set(plainTextByDefault, forKey: Keys.plainTextByDefault) }
    }

    /// Desired launch-at-login state (Mac services engineer applies it with SMAppService).
    @Published public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    /// Max unprotected history items kept (0 = unlimited). Enforced after each ingest.
    @Published public var maxHistoryCount: Int {
        didSet { defaults.set(maxHistoryCount, forKey: Keys.maxHistoryCount) }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// - Parameter defaults: pass a custom suite in tests; nil = App Group defaults.
    public init(defaults: UserDefaults? = nil) {
        let store = defaults ?? AppGroup.userDefaults()
        self.defaults = store
        self.retention = RetentionPolicy(rawValue: store.string(forKey: Keys.retention) ?? "") ?? AppSettings.defaultRetention
        self.capturePaused = store.bool(forKey: Keys.capturePaused)
        self.cloudSyncEnabled = store.bool(forKey: Keys.cloudSyncEnabled)
        self.ignoreRules = AppSettings.loadIgnoreRules(from: store)
        self.plainTextByDefault = store.bool(forKey: Keys.plainTextByDefault)
        self.launchAtLogin = store.bool(forKey: Keys.launchAtLogin)
        if let number = store.object(forKey: Keys.maxHistoryCount) as? NSNumber {
            self.maxHistoryCount = max(0, number.intValue)
        } else {
            self.maxHistoryCount = AppSettings.defaultMaxHistoryCount
        }
        self.hasCompletedOnboarding = store.bool(forKey: Keys.hasCompletedOnboarding)
    }

    /// User-added ignored bundle IDs (the preloaded list is in `IgnoreRules.defaultBundleIDs`).
    public var ignoredBundleIDs: [String] {
        get { return ignoreRules.userBundleIDs }
        set { ignoreRules.userBundleIDs = newValue }
    }

    public func addIgnoredBundleID(_ bundleID: String) {
        var rules = ignoreRules
        rules.add(bundleID)
        ignoreRules = rules
    }

    public func removeIgnoredBundleID(_ bundleID: String) {
        var rules = ignoreRules
        rules.remove(bundleID)
        ignoreRules = rules
    }

    /// Restores every setting to its default value.
    public func resetToDefaults() {
        retention = AppSettings.defaultRetention
        capturePaused = false
        cloudSyncEnabled = false
        ignoreRules = IgnoreRules()
        plainTextByDefault = false
        launchAtLogin = false
        maxHistoryCount = AppSettings.defaultMaxHistoryCount
        hasCompletedOnboarding = false
    }

    // MARK: - Private

    private static func loadIgnoreRules(from defaults: UserDefaults) -> IgnoreRules {
        guard let data = defaults.data(forKey: Keys.ignoreRules) else { return IgnoreRules() }
        return (try? JSONDecoder().decode(IgnoreRules.self, from: data)) ?? IgnoreRules()
    }

    private static func save(_ rules: IgnoreRules, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Keys.ignoreRules)
        }
    }
}
