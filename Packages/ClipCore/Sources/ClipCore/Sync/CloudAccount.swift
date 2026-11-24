import Foundation
import Combine
#if canImport(CloudKit)
import CloudKit
#endif

// "Login" in ClipSync = the Apple Account signed in to iCloud on this device.
// There are no ClipSync accounts or passwords. This file makes that account state
// visible and turns it, together with the sync setting and the running store, into
// one readiness value every screen shows.

/// The iCloud account state of this device, as far as this build can tell.
public enum CloudAccountState: Equatable, Sendable {
    /// Signed in to iCloud and iCloud Drive/CloudKit is usable for this app.
    case available
    /// No Apple Account is signed in to iCloud on this device.
    case noAccount
    /// iCloud is blocked by Screen Time, parental controls or device management.
    case restricted
    /// Signed in, but iCloud is briefly unavailable (e.g. account verification pending).
    case temporarilyUnavailable
    /// CloudKit could not tell (message is user-presentable).
    case couldNotDetermine(String)
    /// This build is not signed with the iCloud entitlement; CloudKit is never called.
    case unsupportedBuild
}

/// Colour hint for status dots.
public enum CloudStatusTone: Equatable, Sendable {
    case good, neutral, warning, problem
}

/// One answer to "is my history syncing, and if not, why?".
public enum CloudSyncReadiness: Equatable, Sendable {
    /// Signed in, sync on, and this session's store mirrors to iCloud.
    case syncing
    /// Signed in and the build supports iCloud, but the sync setting is off.
    case readyButOff
    /// The sync setting differs from what this session's store is doing.
    case needsRelaunch
    /// No iCloud account on this device.
    case signedOut
    /// Development build without the iCloud entitlement.
    case unsupportedBuild
    /// Anything else (restricted, temporarily unavailable, store fell back...).
    case error(String)

    /// Pure mapping: account state × setting × running store → readiness.
    /// - Parameters:
    ///   - state: the iCloud account state.
    ///   - cloudSyncEnabled: `AppSettings.cloudSyncEnabled` (the user's wish).
    ///   - isCloudSyncActive: `ClipStore.isCloudSyncActive` (what this session does).
    ///   - storeError: `ClipStore.storeError` (non-nil after a CloudKit → local fallback).
    public static func resolve(
        state: CloudAccountState,
        cloudSyncEnabled: Bool,
        isCloudSyncActive: Bool,
        storeError: String? = nil
    ) -> CloudSyncReadiness {
        if state == .unsupportedBuild {
            return .unsupportedBuild
        }
        if isCloudSyncActive {
            if !cloudSyncEnabled {
                return .needsRelaunch
            }
            switch state {
            case .available:
                return .syncing
            case .noAccount:
                return .signedOut
            case .restricted:
                return .error(CloudSyncReadiness.restrictedMessage)
            case .temporarilyUnavailable:
                return .error(CloudSyncReadiness.temporarilyUnavailableMessage)
            case .couldNotDetermine(let message):
                return .error(message)
            case .unsupportedBuild:
                return .unsupportedBuild
            }
        }

        // This session is local-only.
        if cloudSyncEnabled {
            switch state {
            case .noAccount:
                return .signedOut
            case .restricted:
                return .error(CloudSyncReadiness.restrictedMessage)
            default:
                break
            }
            if let error = storeError, !error.isEmpty {
                // The store tried iCloud at launch and fell back; a relaunch won't fix it.
                return .error(error)
            }
            return .needsRelaunch
        }

        switch state {
        case .available:
            return .readyButOff
        case .noAccount:
            return .signedOut
        case .restricted:
            return .error(CloudSyncReadiness.restrictedMessage)
        case .temporarilyUnavailable:
            return .error(CloudSyncReadiness.temporarilyUnavailableMessage)
        case .couldNotDetermine(let message):
            return .error(message)
        case .unsupportedBuild:
            return .unsupportedBuild
        }
    }

    static let restrictedMessage = "iCloud is restricted on this device (Screen Time or device management)."
    static let temporarilyUnavailableMessage = "iCloud is temporarily unavailable. Try again in a moment."

    /// Short title for a status row.
    public var title: String {
        switch self {
        case .syncing:
            return "Syncing with iCloud"
        case .readyButOff:
            return "iCloud ready, sync is off"
        case .needsRelaunch:
            return "Relaunch to apply"
        case .signedOut:
            return "Not signed in to iCloud"
        case .unsupportedBuild:
            return "iCloud not available in this build"
        case .error:
            return "iCloud problem"
        }
    }

    /// One or two plain sentences under the title.
    public var explanation: String {
        switch self {
        case .syncing:
            return "History syncs through your private iCloud database to your other devices signed in to the same Apple Account."
        case .readyButOff:
            return "You are signed in to iCloud. Turn on sync to share history with your other devices."
        case .needsRelaunch:
            return "The sync setting takes effect the next time ClipSync starts. History keeps working on this device."
        case .signedOut:
            #if os(macOS)
            return "Sign in to iCloud in System Settings to sync. History keeps working on this Mac."
            #else
            return "Sign in to iCloud in the Settings app to sync. History keeps working on this device."
            #endif
        case .unsupportedBuild:
            if CloudBuildSupport.isSignedConfiguration {
                return "This build is signed, but without iCloud permission. Check the team's iCloud container in Xcode. History keeps working on this device."
            }
            return "This is a development build that is not signed with an Apple Developer team, so it cannot use iCloud. Everything works on this device; sync becomes available in a signed build."
        case .error(let message):
            return message + " History keeps working on this device."
        }
    }

    /// Colour hint for the status dot.
    public var tone: CloudStatusTone {
        switch self {
        case .syncing:
            return .good
        case .readyButOff, .unsupportedBuild:
            return .neutral
        case .needsRelaunch, .signedOut:
            return .warning
        case .error:
            return .problem
        }
    }

    /// False when turning sync ON could not work (no account / no entitlement).
    /// Turning it OFF is always allowed.
    public var allowsEnablingSync: Bool {
        switch self {
        case .signedOut, .unsupportedBuild:
            return false
        default:
            return true
        }
    }

    /// Why the sync toggle can't be turned on, or nil.
    public var disabledReason: String? {
        switch self {
        case .signedOut:
            return "Sign in to iCloud on this device first."
        case .unsupportedBuild:
            return "Needs a build signed with an Apple Developer team."
        default:
            return nil
        }
    }
}

/// Async source of the account state (injectable for tests; must not touch CloudKit
/// unless `CloudBuildSupport.isCloudKitAvailable`).
public typealias CloudAccountStatusProvider = @Sendable () async -> CloudAccountState

/// Publishes the device's iCloud account state. Refreshes on creation, on
/// `.CKAccountChanged` / `NSUbiquityIdentityDidChange`, and when you call `refresh()`.
/// Use `CloudAccountMonitor.shared` from views (read it inside `body`).
@MainActor
public final class CloudAccountMonitor: ObservableObject {

    private static var sharedInstance: CloudAccountMonitor?

    /// Process-wide monitor (live CloudKit provider, gated by the entitlement check).
    public static var shared: CloudAccountMonitor {
        if let monitor = sharedInstance {
            return monitor
        }
        let monitor = CloudAccountMonitor()
        sharedInstance = monitor
        return monitor
    }

    /// Replaces `shared` (tests, previews).
    public static func setShared(_ monitor: CloudAccountMonitor) {
        sharedInstance = monitor
    }

    /// Current account state. `.unsupportedBuild` from the start in unentitled builds.
    @Published public private(set) var state: CloudAccountState
    /// True while a check is in flight.
    @Published public private(set) var isRefreshing: Bool = false
    /// When the last check finished (nil = never checked yet).
    @Published public private(set) var lastChecked: Date? = nil

    /// Optional: attach these so `syncReadiness` can combine everything.
    public var settings: AppSettings?
    public var store: ClipStore?

    /// False in unentitled builds: CloudKit is never touched.
    public let isSupportedBuild: Bool

    private let provider: CloudAccountStatusProvider
    private var cancellables = Set<AnyCancellable>()

    /// - Parameters:
    ///   - isSupportedBuild: defaults to `CloudBuildSupport.isCloudKitAvailable`.
    ///   - provider: defaults to the live CloudKit query.
    ///   - observesAccountChanges: refresh on `.CKAccountChanged` / `NSUbiquityIdentityDidChange`.
    ///   - refreshesImmediately: start a check right away (off in tests).
    public init(
        isSupportedBuild: Bool = CloudBuildSupport.isCloudKitAvailable,
        provider: CloudAccountStatusProvider? = nil,
        observesAccountChanges: Bool = true,
        refreshesImmediately: Bool = true
    ) {
        self.isSupportedBuild = isSupportedBuild
        if let custom = provider {
            self.provider = custom
        } else {
            self.provider = { await CloudAccountMonitor.liveStatus() }
        }
        if isSupportedBuild {
            self.state = .couldNotDetermine("Checking your iCloud account…")
        } else {
            self.state = .unsupportedBuild
        }

        guard isSupportedBuild else { return }

        if observesAccountChanges {
            var names: [Notification.Name] = [.NSUbiquityIdentityDidChange]
            #if canImport(CloudKit)
            names.append(.CKAccountChanged)
            #endif
            for name in names {
                NotificationCenter.default.publisher(for: name)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        self?.refreshInBackground()
                    }
                    .store(in: &cancellables)
            }
        }
        if refreshesImmediately {
            refreshInBackground()
        }
    }

    /// True once at least one check finished (or the build is unsupported).
    public var hasChecked: Bool {
        return !isSupportedBuild || lastChecked != nil
    }

    /// Readiness using the attached `settings` / `store` (nil → sync off / local only).
    public var syncReadiness: CloudSyncReadiness {
        return CloudSyncReadiness.resolve(
            state: state,
            cloudSyncEnabled: settings?.cloudSyncEnabled ?? false,
            isCloudSyncActive: store?.isCloudSyncActive ?? false,
            storeError: store?.storeError
        )
    }

    /// Readiness for explicit settings/store (preferred in views that observe them).
    public func readiness(settings: AppSettings, store: ClipStore) -> CloudSyncReadiness {
        return CloudSyncReadiness.resolve(
            state: state,
            cloudSyncEnabled: settings.cloudSyncEnabled,
            isCloudSyncActive: store.isCloudSyncActive,
            storeError: store.storeError
        )
    }

    /// Attaches the objects `syncReadiness` reads.
    public func attach(settings: AppSettings, store: ClipStore) {
        self.settings = settings
        self.store = store
    }

    /// Re-checks the account. Never calls CloudKit in an unsupported build.
    public func refresh() async {
        guard isSupportedBuild else {
            if state != .unsupportedBuild {
                state = .unsupportedBuild
            }
            return
        }
        isRefreshing = true
        let fetch = provider
        let newState = await fetch()
        isRefreshing = false
        lastChecked = Date()
        if newState != state {
            state = newState
        }
    }

    /// Fire-and-forget `refresh()` (for synchronous call sites).
    public func refreshInBackground() {
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Live CloudKit query

    /// The live provider. Returns `.unsupportedBuild` without touching CloudKit when
    /// the process lacks the entitlement.
    public nonisolated static func liveStatus() async -> CloudAccountState {
        guard CloudBuildSupport.isCloudKitAvailable else {
            return .unsupportedBuild
        }
        #if canImport(CloudKit)
        do {
            let container = CKContainer(identifier: ClipConstants.iCloudContainerID)
            let status = try await container.accountStatus()
            return CloudAccountMonitor.map(status)
        } catch {
            return .couldNotDetermine("Could not check iCloud: \(error.localizedDescription)")
        }
        #else
        return .unsupportedBuild
        #endif
    }

    #if canImport(CloudKit)
    nonisolated static func map(_ status: CKAccountStatus) -> CloudAccountState {
        switch status {
        case .available:
            return .available
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        case .couldNotDetermine:
            return .couldNotDetermine("iCloud did not report an account status.")
        @unknown default:
            return .couldNotDetermine("iCloud reported an unknown account status.")
        }
    }
    #endif
}
