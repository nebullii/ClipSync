import AppIntents
import ClipCore

/// Lets Xcode's App Intents metadata extraction find the intents, `ClipEntity` and the
/// `AppShortcutsProvider` that live in the ClipCore static library.
struct ClipSyncAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [ClipCoreAppIntentsPackage.self]
    }
}
