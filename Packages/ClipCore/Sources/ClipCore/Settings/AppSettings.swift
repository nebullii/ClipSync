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
        // Security & privacy (additive).
        public static let appLockEnabled = "clipsync.appLockEnabled"
        public static let lockTimeout = "clipsync.lockTimeout"
        public static let linkPreviewsEnabled = "clipsync.linkPreviewsEnabled"
        public static let hideFromScreenCapture = "clipsync.hideFromScreenCapture"
        public static let privacyCoverEnabled = "clipsync.privacyCoverEnabled"
        public static let clearHistoryOnQuit = "clipsync.clearHistoryOnQuit"
        public static let playCopySound = "clipsync.playCopySound"
        public static let copySoundName = "clipsync.copySoundName"
        public static let copySoundFilePath = "clipsync.copySoundFilePath"
    }

    public static let defaultRetention: RetentionPolicy = .month
    public static let defaultMaxHistoryCount = 10_000
    /// macOS system sound (in /System/Library/Sounds) played on copy until the user picks one.
    public static let defaultCopySoundName = "Tink"
    /// `copySoundName` value meaning "play the file at `copySoundFilePath`".
    public static let customCopySoundName = "Custom File"
    /// App Lock auto-lock delay used until the user picks one.
    public static let defaultLockTimeout: LockTimeout = .after5Minutes

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
            Keys.plainTextByDefault, Keys.launchAtLogin, Keys.maxHistoryCount, Keys.hasCompletedOnboarding,
            Keys.appLockEnabled, Keys.lockTimeout, Keys.linkPreviewsEnabled, Keys.hideFromScreenCapture,
            Keys.privacyCoverEnabled, Keys.clearHistoryOnQuit, Keys.playCopySound, Keys.copySoundName, Keys.copySoundFilePath
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

    // MARK: Security & privacy

    /// App Lock (Touch ID / Face ID / device password). Default OFF.
    /// Read-only outside ClipCore on purpose: turn it on or off with
    /// `AppLockController.setEnabled(_:reason:)`, which requires a successful authentication.
    @Published public internal(set) var appLockEnabled: Bool {
        didSet { defaults.set(appLockEnabled, forKey: Keys.appLockEnabled) }
    }

    /// How long after the history was last hidden ClipSync locks again. Default 5 minutes.
    @Published public var lockTimeout: LockTimeout {
        didSet { defaults.set(lockTimeout.rawValue, forKey: Keys.lockTimeout) }
    }

    /// Fetch link titles and icons (contacts the linked website). Default OFF: with it off,
    /// ClipSync makes no network requests of its own (iCloud sync is a separate opt-in).
    @Published public var linkPreviewsEnabled: Bool {
        didSet { defaults.set(linkPreviewsEnabled, forKey: Keys.linkPreviewsEnabled) }
    }

    /// Mac: ask macOS to leave ClipSync windows out of screen recordings / screen sharing
    /// (`NSWindow.sharingType = .none`). Default ON. Apps keep it off in UI-test mode.
    @Published public var hideFromScreenCapture: Bool {
        didSet { defaults.set(hideFromScreenCapture, forKey: Keys.hideFromScreenCapture) }
    }

    /// iOS: cover the window while the app is inactive / in the background, so the app
    /// switcher snapshot never shows clipboard content. Default ON.
    @Published public var privacyCoverEnabled: Bool {
        didSet { defaults.set(privacyCoverEnabled, forKey: Keys.privacyCoverEnabled) }
    }

    /// Mac: delete unpinned history when ClipSync quits normally. Default OFF.
    @Published public var clearHistoryOnQuit: Bool {
        didSet { defaults.set(clearHistoryOnQuit, forKey: Keys.clearHistoryOnQuit) }
    }

    /// Mac: play a short sound each time ClipSync saves something you copied. Default ON.
    @Published public var playCopySound: Bool {
        didSet { defaults.set(playCopySound, forKey: Keys.playCopySound) }
    }

    /// Mac: which macOS system sound the copy sound uses (a name like "Tink" or "Pop").
    @Published public var copySoundName: String {
        didSet { defaults.set(copySoundName, forKey: Keys.copySoundName) }
    }

    /// Mac: a sound file the user chose (ClipSync keeps its own copy). Empty = none.
    @Published public var copySoundFilePath: String {
        didSet { defaults.set(copySoundFilePath, forKey: Keys.copySoundFilePath) }
    }

    /// - Parameter defaults: pass a custom suite in tests; nil = App Group defaults.
    public init(defaults: UserDefaults? = nil) {
        let store = defaults ?? AppGroup.userDefaults()
        self.defaults = store
        self.retention = RetentionPolicy(rawValue: store.string(forKey: Keys.retention) ?? "") ?? AppSettings.defaultRetention
        self.capturePaused = store.bool(forKey: Keys.capturePaused)
        if let storedSync = store.object(forKey: Keys.cloudSyncEnabled) as? NSNumber {
            self.cloudSyncEnabled = storedSync.boolValue
        } else {
            // Never chosen: ON only for the real (App Group) defaults of a Signed build that
            // can use CloudKit (Info.plist ClipSyncCloudDefault). Custom suites stay OFF.
            self.cloudSyncEnabled = (defaults == nil) && CloudBuildSupport.defaultCloudSyncEnabled
        }
        self.ignoreRules = AppSettings.loadIgnoreRules(from: store)
        self.plainTextByDefault = store.bool(forKey: Keys.plainTextByDefault)
        self.launchAtLogin = store.bool(forKey: Keys.launchAtLogin)
        if let number = store.object(forKey: Keys.maxHistoryCount) as? NSNumber {
            self.maxHistoryCount = max(0, number.intValue)
        } else {
            self.maxHistoryCount = AppSettings.defaultMaxHistoryCount
        }
        self.hasCompletedOnboarding = store.bool(forKey: Keys.hasCompletedOnboarding)
        self.appLockEnabled = store.bool(forKey: Keys.appLockEnabled)
        self.lockTimeout = LockTimeout(rawValue: store.string(forKey: Keys.lockTimeout) ?? "") ?? AppSettings.defaultLockTimeout
        self.linkPreviewsEnabled = store.bool(forKey: Keys.linkPreviewsEnabled)
        self.hideFromScreenCapture = AppSettings.bool(forKey: Keys.hideFromScreenCapture, in: store, default: true)
        self.privacyCoverEnabled = AppSettings.bool(forKey: Keys.privacyCoverEnabled, in: store, default: true)
        self.clearHistoryOnQuit = store.bool(forKey: Keys.clearHistoryOnQuit)
        self.playCopySound = AppSettings.bool(forKey: Keys.playCopySound, in: store, default: true)
        let storedSound = store.string(forKey: Keys.copySoundName) ?? ""
        self.copySoundName = storedSound.isEmpty ? AppSettings.defaultCopySoundName : storedSound
        self.copySoundFilePath = store.string(forKey: Keys.copySoundFilePath) ?? ""
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

    /// Restores every setting to its default value — except App Lock (`appLockEnabled`,
    /// `lockTimeout`), which only `AppLockController` changes, after authentication.
    public func resetToDefaults() {
        retention = AppSettings.defaultRetention
        capturePaused = false
        cloudSyncEnabled = false
        ignoreRules = IgnoreRules()
        plainTextByDefault = false
        launchAtLogin = false
        maxHistoryCount = AppSettings.defaultMaxHistoryCount
        hasCompletedOnboarding = false
        linkPreviewsEnabled = false
        hideFromScreenCapture = true
        privacyCoverEnabled = true
        clearHistoryOnQuit = false
        playCopySound = true
        copySoundName = AppSettings.defaultCopySoundName
        copySoundFilePath = ""
    }

    // MARK: - Private

    private static func bool(forKey key: String, in defaults: UserDefaults, default fallback: Bool) -> Bool {
        if let number = defaults.object(forKey: key) as? NSNumber {
            return number.boolValue
        }
        return fallback
    }

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
