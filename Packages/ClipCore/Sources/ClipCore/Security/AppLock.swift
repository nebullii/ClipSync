import Foundation
import Combine
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

// App Lock: ClipSync's "login". Hides clipboard history behind Touch ID / Face ID /
// Optic ID with the device password (Mac) or passcode (iPhone/iPad) as fallback.
//
// What it is: an access gate in the ClipSync UI, Shortcuts/App Intents and the Mac menu bar.
// What it is NOT: encryption. The history database is protected at rest only by the
// operating system (FileVault on the Mac, iOS Data Protection) — see docs/SECURITY.md.
//
// The controller is platform-neutral and unit-testable: authentication goes through
// `AppLockAuthenticating` (LocalAuthentication in the apps, a fake in tests) and time
// through `AppLockClock` (a monotonic clock that keeps counting during sleep).
// Platform code calls `lockNow()` on screen lock / sleep / user switch, `noteInterfaceHidden()`
// when the history UI goes away, and `checkTimeout()` before it shows history again.

/// Auto-lock delay after the history was last hidden / the app was last used.
public enum LockTimeout: String, CaseIterable, Codable, Sendable, Identifiable {
    case immediately, after1Minute, after5Minutes, after15Minutes, after1Hour

    public var id: String { return rawValue }

    public var displayName: String {
        switch self {
        case .immediately: return "Immediately"
        case .after1Minute: return "After 1 minute"
        case .after5Minutes: return "After 5 minutes"
        case .after15Minutes: return "After 15 minutes"
        case .after1Hour: return "After 1 hour"
        }
    }

    /// Seconds of inactivity before locking; nil = lock as soon as the history is hidden.
    public var interval: TimeInterval? {
        switch self {
        case .immediately: return nil
        case .after1Minute: return 60
        case .after5Minutes: return 5 * 60
        case .after15Minutes: return 15 * 60
        case .after1Hour: return 60 * 60
        }
    }
}

/// The biometric sensor the device offers (none = password / passcode only).
public enum BiometryKind: String, Sendable, Equatable {
    case none, touchID, faceID, opticID

    /// "Touch ID", "Face ID", "Optic ID"; nil when there is no biometric sensor.
    public var displayName: String? {
        switch self {
        case .none: return nil
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        }
    }

    /// SF Symbol for unlock buttons.
    public var systemImageName: String {
        switch self {
        case .none: return "lock.open"
        case .touchID: return "touchid"
        case .faceID: return "faceid"
        case .opticID: return "opticid"
        }
    }
}

/// Whether this device can verify its owner at all.
public struct AppLockAvailability: Sendable, Equatable {
    /// True when a password/passcode (and optionally biometrics) is set up.
    public var canAuthenticate: Bool
    public var biometryKind: BiometryKind
    /// User-presentable explanation when `canAuthenticate` is false.
    public var unavailableReason: String?

    public init(canAuthenticate: Bool, biometryKind: BiometryKind, unavailableReason: String? = nil) {
        self.canAuthenticate = canAuthenticate
        self.biometryKind = biometryKind
        self.unavailableReason = unavailableReason
    }
}

/// Outcome of one authentication attempt.
public enum AppLockAuthResult: Sendable, Equatable {
    case success
    /// The user (or the system, e.g. on sleep) cancelled the prompt.
    case cancelled
    /// Authentication failed (message is user-presentable).
    case failed(String)
    /// The device cannot authenticate (no passcode / password set up).
    case unavailable(String)
}

/// Outcome of turning App Lock on or off.
public enum AppLockChangeResult: Sendable, Equatable {
    case changed
    case cancelled
    case failed(String)
    /// Turning the lock on was refused because the device cannot authenticate.
    case unavailable(String)
}

/// Verifies the device owner. The apps use `LocalAuthenticationAuthenticator`; tests a fake.
@MainActor
public protocol AppLockAuthenticating: AnyObject {
    func availability() -> AppLockAvailability
    func authenticate(reason: String) async -> AppLockAuthResult
}

/// Monotonic seconds that keep counting while the device sleeps (so a timeout can't be
/// dodged by closing the lid) and never jump when the user changes the wall clock.
public protocol AppLockClock: AnyObject {
    func now() -> TimeInterval
}

/// `ContinuousClock`-based (keeps counting during system sleep, unlike uptime).
public final class ContinuousAppLockClock: AppLockClock {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public func now() -> TimeInterval {
        let elapsed: Duration = origin.duration(to: ContinuousClock.now)
        let parts = elapsed.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Controller

@MainActor
public final class AppLockController: ObservableObject {
    /// Error text used everywhere content is refused while locked (intents, test driver).
    nonisolated public static let lockedMessage = "ClipSync is locked. Unlock it in the app, then try again."

    private static var sharedInstance: AppLockController?

    /// Process-wide controller for `AppSettings.shared` with the system authenticator.
    /// Created lazily: read it only AFTER `AppSettings.setShared(_:)` (UI-test mode).
    public static var shared: AppLockController {
        if let existing = sharedInstance {
            return existing
        }
        let controller = AppLockController(settings: AppSettings.shared, authenticator: AppLockController.makeSystemAuthenticator())
        sharedInstance = controller
        return controller
    }

    /// Replaces `shared` (e.g. a controller bound to UI-test settings).
    public static func setShared(_ controller: AppLockController) {
        sharedInstance = controller
    }

    /// LocalAuthentication where available, else an authenticator that always reports "unavailable".
    public static func makeSystemAuthenticator() -> AppLockAuthenticating {
        #if canImport(LocalAuthentication)
        return LocalAuthenticationAuthenticator()
        #else
        return UnavailableAuthenticator()
        #endif
    }

    public let settings: AppSettings
    private let authenticator: AppLockAuthenticating
    private let clock: AppLockClock

    /// True while history must not be shown or returned. Starts locked when the lock is on.
    @Published public private(set) var isLocked: Bool {
        didSet {
            if oldValue != isLocked {
                notifyObservers()
            }
        }
    }
    /// True while a system authentication prompt is up.
    @Published public private(set) var isAuthenticating = false
    @Published public private(set) var biometryKind: BiometryKind = .none
    /// False when the device has no password / passcode (then the lock cannot be turned on).
    @Published public private(set) var canAuthenticate = false
    /// Last user-presentable problem (failed attempt, unavailable device), nil when fine.
    @Published public private(set) var lastMessage: String? = nil

    /// Apps set this to false in UI-test mode, so showing locked UI never opens a system prompt.
    public var autoPromptOnShow = true

    private var lastActivity: TimeInterval
    private var observers: [@MainActor (Bool) -> Void] = []

    public init(settings: AppSettings, authenticator: AppLockAuthenticating, clock: AppLockClock? = nil) {
        self.settings = settings
        self.authenticator = authenticator
        let resolvedClock = clock ?? ContinuousAppLockClock()
        self.clock = resolvedClock
        self.lastActivity = resolvedClock.now()
        self.isLocked = settings.appLockEnabled
        refreshAvailability()
    }

    // MARK: State

    /// The user's choice (persisted in `AppSettings.appLockEnabled`).
    public var isEnabled: Bool {
        return settings.appLockEnabled
    }

    public var timeout: LockTimeout {
        return settings.lockTimeout
    }

    /// "Unlock with Touch ID" / "Unlock with Face ID" / "Unlock".
    public var unlockButtonTitle: String {
        if let name = biometryKind.displayName {
            return "Unlock with \(name)"
        }
        return "Unlock"
    }

    /// Re-reads biometry kind and whether the device can authenticate.
    public func refreshAvailability() {
        let availability = authenticator.availability()
        if biometryKind != availability.biometryKind {
            biometryKind = availability.biometryKind
        }
        if canAuthenticate != availability.canAuthenticate {
            canAuthenticate = availability.canAuthenticate
        }
    }

    /// Called with the new `isLocked` value after every change (synchronously, main actor).
    public func addLockStateObserver(_ handler: @escaping @MainActor (Bool) -> Void) {
        observers.append(handler)
    }

    private func notifyObservers() {
        let value = isLocked
        for handler in observers {
            handler(value)
        }
    }

    // MARK: Locking

    /// Locks right away (screen lock, sleep, user switch, "Lock ClipSync Now"). No-op when the lock is off.
    public func lockNow() {
        guard isEnabled else { return }
        if !isLocked {
            isLocked = true
        }
    }

    /// The user did something with unlocked history: restarts the inactivity timer.
    public func noteActivity() {
        guard !isLocked else { return }
        lastActivity = clock.now()
    }

    /// The history UI was hidden (Mac panel closed, iOS app went to the background).
    /// With the "Immediately" timeout this locks; otherwise the timeout starts now.
    public func noteInterfaceHidden() {
        guard isEnabled, !isLocked else { return }
        if timeout.interval == nil {
            lockNow()
        } else {
            lastActivity = clock.now()
        }
    }

    /// Locks when the timeout has passed since the last activity. Call before showing or
    /// returning history. Returns `isLocked`.
    @discardableResult
    public func checkTimeout() -> Bool {
        guard isEnabled else { return isLocked }
        guard !isLocked else { return true }
        guard let interval = timeout.interval else { return false }
        if clock.now() - lastActivity >= interval {
            isLocked = true
        }
        return isLocked
    }

    // MARK: Unlocking

    /// Shows the system prompt (biometrics with password / passcode fallback).
    /// Returns true when history may be shown.
    @discardableResult
    public func unlock(reason: String) async -> Bool {
        guard isLocked else { return true }
        guard !isAuthenticating else { return false }
        refreshAvailability()
        if !canAuthenticate {
            // Nobody can be verified on a device without a password/passcode; refusing
            // forever would only lock the owner out of their own history.
            let availability = authenticator.availability()
            unlockWithoutVerification(reason: availability.unavailableReason)
            return true
        }
        isAuthenticating = true
        let result = await authenticator.authenticate(reason: reason)
        isAuthenticating = false
        switch result {
        case .success:
            lastMessage = nil
            lastActivity = clock.now()
            isLocked = false
            return true
        case .cancelled:
            lastMessage = nil
            return false
        case .failed(let message):
            lastMessage = message
            return false
        case .unavailable(let message):
            unlockWithoutVerification(reason: message)
            return true
        }
    }

    private func unlockWithoutVerification(reason: String?) {
        let detail = reason ?? "This device has no password or passcode."
        lastMessage = "\(detail) ClipSync was unlocked without verification; App Lock cannot protect your history until you set one up."
        lastActivity = clock.now()
        isLocked = false
    }

    // MARK: Turning the lock on / off (both require authentication)

    /// Turns App Lock on or off. Both directions require a successful authentication;
    /// turning it on is refused when the device cannot authenticate at all.
    public func setEnabled(_ enabled: Bool, reason: String) async -> AppLockChangeResult {
        guard enabled != isEnabled else { return .changed }
        guard !isAuthenticating else { return .cancelled }
        refreshAvailability()
        if !canAuthenticate {
            let message = authenticator.availability().unavailableReason ?? AppLockController.noPasscodeMessage
            if enabled {
                lastMessage = message
                return .unavailable(message)
            }
            // Turning OFF on a device that can no longer verify anyone (passcode removed,
            // which itself required the passcode): allowed, nothing left to protect with.
            settings.appLockEnabled = false
            isLocked = false
            lastMessage = nil
            return .changed
        }
        isAuthenticating = true
        let result = await authenticator.authenticate(reason: reason)
        isAuthenticating = false
        switch result {
        case .success:
            settings.appLockEnabled = enabled
            lastActivity = clock.now()
            isLocked = false
            lastMessage = nil
            return .changed
        case .cancelled:
            lastMessage = nil
            return .cancelled
        case .failed(let message):
            lastMessage = message
            return .failed(message)
        case .unavailable(let message):
            lastMessage = message
            return .unavailable(message)
        }
    }

    /// Shown when turning the lock on is impossible.
    nonisolated public static let noPasscodeMessage = "App Lock needs a password or passcode on this device. Set one up in System Settings (Mac) or Settings › Face ID & Passcode (iPhone/iPad), then try again."

    public func clearMessage() {
        lastMessage = nil
    }

    // MARK: Test hooks (Debug builds only; never compiled into Release/Signed builds)

    #if DEBUG
    /// E2E driver only: turns the lock on WITHOUT authentication.
    public func enableForTesting() {
        settings.appLockEnabled = true
        lastActivity = clock.now()
    }

    /// E2E driver only: unlocks without the system prompt and turns the lock off again.
    public func unlockAndDisableForTesting() {
        isLocked = false
        settings.appLockEnabled = false
        lastActivity = clock.now()
        lastMessage = nil
    }
    #endif
}

// MARK: - LocalAuthentication

#if canImport(LocalAuthentication)
/// `LAContext` with `.deviceOwnerAuthentication`: biometrics when enrolled, otherwise
/// (or after a biometric failure / lockout) the Mac password or device passcode.
@MainActor
public final class LocalAuthenticationAuthenticator: AppLockAuthenticating {
    public init() {}

    public func availability() -> AppLockAvailability {
        let probe = LAContext()
        var biometricError: NSError?
        _ = probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)
        let kind = LocalAuthenticationSupport.biometryKind(of: probe)

        let context = LAContext()
        var error: NSError?
        let canAuthenticate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if canAuthenticate {
            return AppLockAvailability(canAuthenticate: true, biometryKind: kind, unavailableReason: nil)
        }
        return AppLockAvailability(
            canAuthenticate: false,
            biometryKind: kind,
            unavailableReason: LocalAuthenticationSupport.unavailableMessage(for: error)
        )
    }

    public func authenticate(reason: String) async -> AppLockAuthResult {
        let context = LAContext()
        return await LocalAuthenticationSupport.evaluate(context: context, reason: reason)
    }
}

/// Non-isolated helpers: LocalAuthentication calls its reply block on a private queue.
enum LocalAuthenticationSupport {
    static func evaluate(context: LAContext, reason: String) async -> AppLockAuthResult {
        return await withCheckedContinuation { (continuation: CheckedContinuation<AppLockAuthResult, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { @Sendable success, error in
                continuation.resume(returning: LocalAuthenticationSupport.result(success: success, error: error))
            }
        }
    }

    static func result(success: Bool, error: Error?) -> AppLockAuthResult {
        if success {
            return .success
        }
        guard let laError = error as? LAError else {
            return .failed("ClipSync could not verify you. Try again.")
        }
        switch laError.code {
        case .userCancel, .systemCancel, .appCancel, .userFallback:
            return .cancelled
        case .passcodeNotSet:
            return .unavailable(AppLockController.noPasscodeMessage)
        case .authenticationFailed:
            return .failed("That didn't match. Try again.")
        default:
            return .failed("ClipSync could not verify you (\(laError.localizedDescription)). Try again.")
        }
    }

    static func biometryKind(of context: LAContext) -> BiometryKind {
        switch context.biometryType {
        case .touchID:
            return .touchID
        case .faceID:
            return .faceID
        case .opticID:
            return .opticID
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }

    static func unavailableMessage(for error: NSError?) -> String {
        guard let error = error else { return AppLockController.noPasscodeMessage }
        if error.domain == LAError.errorDomain, error.code == LAError.Code.passcodeNotSet.rawValue {
            return AppLockController.noPasscodeMessage
        }
        return "This device can't verify you right now (\(error.localizedDescription))."
    }
}
#endif

/// Used only where LocalAuthentication does not exist (never on macOS 14+/iOS 17+).
@MainActor
final class UnavailableAuthenticator: AppLockAuthenticating {
    func availability() -> AppLockAvailability {
        return AppLockAvailability(canAuthenticate: false, biometryKind: .none, unavailableReason: AppLockController.noPasscodeMessage)
    }

    func authenticate(reason: String) async -> AppLockAuthResult {
        return .unavailable(AppLockController.noPasscodeMessage)
    }
}
