import Foundation
#if os(macOS)
import Security
#endif

/// Answers "may this process call CloudKit at all?" WITHOUT touching CloudKit.
///
/// `CKContainer(identifier:)` / `CKContainer.default()` raise an Objective-C exception
/// (an uncatchable crash) in a process that is not signed with the iCloud/CloudKit
/// entitlement, which is every unsigned / ad-hoc development build. Every CloudKit call
/// in ClipSync must be gated by `CloudBuildSupport.isCloudKitAvailable`.
///
/// - macOS: exact. Reads the process's own `com.apple.developer.icloud-container-identifiers`
///   and `com.apple.developer.icloud-services` entitlements with SecTask (like `AppGroup`).
/// - iOS / iPadOS: there is no public SecTask API, so a conservative heuristic that can
///   only err on the side of "unsupported":
///     1. the Info.plist key `ClipSyncCloudKitEntitled` is YES (set only by the `Signed`
///        build configuration, which is the only one that applies the entitlements), AND
///     2. the App Group container is reachable (`AppGroup.containerURL() != nil`), AND
///     3. device: `embedded.mobileprovision` exists and its entitlements list our iCloud
///        container; Simulator: there is no profile, so 1 + 2 decide.
public enum CloudBuildSupport {
    /// Info.plist key (Bool or "YES"/"NO" string): this build was produced by the `Signed`
    /// configuration, i.e. with the iCloud/App Group entitlements applied.
    public static let entitledInfoKey = "ClipSyncCloudKitEntitled"
    /// Info.plist key (Bool or "YES"/"NO" string): default for `cloudSyncEnabled` when the
    /// user never chose. YES only in the `Signed` configuration.
    public static let cloudDefaultInfoKey = "ClipSyncCloudDefault"

    /// The CloudKit entitlement key checked on macOS.
    public static let containerEntitlementKey = "com.apple.developer.icloud-container-identifiers"
    /// The iCloud services entitlement key checked on macOS.
    public static let servicesEntitlementKey = "com.apple.developer.icloud-services"

    /// True only when CloudKit APIs can be called without crashing. Evaluated once per process.
    public static var isCloudKitAvailable: Bool {
        return cachedAvailability
    }

    /// True when the build was made with the `Signed` configuration (Info.plist flag).
    /// Used for honest explanations ("signed, but the iCloud permission is missing").
    public static var isSignedConfiguration: Bool {
        return infoFlag(entitledInfoKey)
    }

    /// Default for `AppSettings.cloudSyncEnabled` when the user has never set it:
    /// ON only in a Signed build that really can use CloudKit, OFF everywhere else.
    public static var defaultCloudSyncEnabled: Bool {
        return infoFlag(cloudDefaultInfoKey) && isCloudKitAvailable
    }

    private static let cachedAvailability: Bool = evaluate()

    private static func evaluate() -> Bool {
        #if os(macOS)
        return macOSHasCloudKitEntitlement()
        #else
        guard infoFlag(entitledInfoKey) else { return false }
        guard AppGroup.containerURL() != nil else { return false }
        #if targetEnvironment(simulator)
        // Simulator builds carry no provisioning profile; the Signed configuration embeds
        // the entitlements in the binary, and the App Group check above confirms them.
        return true
        #else
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return false
        }
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return profileGrantsICloud(data, containerID: ClipConstants.iCloudContainerID)
        #endif
        #endif
    }

    #if os(macOS)
    private static func macOSHasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let containers = SecTaskCopyValueForEntitlement(task, containerEntitlementKey as CFString, nil)
        guard let ids = containers as? [String], ids.contains(ClipConstants.iCloudContainerID) else {
            return false
        }
        let services = SecTaskCopyValueForEntitlement(task, servicesEntitlementKey as CFString, nil)
        if let list = services as? [String] {
            return list.contains("CloudKit") || list.contains("*")
        }
        if let single = services as? String {
            return single == "CloudKit" || single == "*"
        }
        return false
    }
    #endif

    /// True when a provisioning profile (CMS-wrapped XML plist) grants our iCloud container.
    /// Pure and platform-independent so it can be unit-tested.
    static func profileGrantsICloud(_ data: Data, containerID: String) -> Bool {
        guard let start = data.range(of: Data("<?xml".utf8)) else { return false }
        guard let end = data.range(of: Data("</plist>".utf8), options: [], in: start.lowerBound..<data.endIndex) else {
            return false
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let root = object as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any] else {
            return false
        }
        let containers = entitlements[containerEntitlementKey] as? [String] ?? []
        return containers.contains(containerID) || containers.contains("*")
    }

    /// Reads a Bool-ish Info.plist value (Bool, NSNumber, or "YES"/"true"/"1" string).
    static func infoFlag(_ key: String, bundle: Bundle = Bundle.main) -> Bool {
        let value = bundle.object(forInfoDictionaryKey: key)
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "yes" || normalized == "true" || normalized == "1"
        }
        return false
    }
}
