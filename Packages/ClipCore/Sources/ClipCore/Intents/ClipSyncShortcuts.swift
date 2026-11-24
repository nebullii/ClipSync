import Foundation
import AppIntents

// Owned by the extensions engineer.

/// App Intents package marker for ClipCore. Each app target declares its own package
/// that includes this one so Xcode's metadata extraction picks up the intents and the
/// `ClipEntity` defined in this static library:
///
///     struct ClipSyncAppIntentsPackage: AppIntentsPackage {
///         static var includedPackages: [any AppIntentsPackage.Type] { [ClipCoreAppIntentsPackage.self] }
///     }
///
/// If Shortcuts still does not list the actions after a build, use the wrapper-intent
/// fallback (thin intents in the app target that call `ClipIntentRunner`).
public struct ClipCoreAppIntentsPackage: AppIntentsPackage {}

/// Siri / Spotlight / Shortcuts app phrases. Every phrase contains `\(.applicationName)`.
public struct ClipSyncShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveClipboardIntent(),
            phrases: [
                "Save my clipboard to \(.applicationName)",
                "Save clipboard in \(.applicationName)",
                "Add the clipboard to \(.applicationName)"
            ],
            shortTitle: "Save Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: SaveTextIntent(),
            phrases: [
                "Save text to \(.applicationName)",
                "Add text to \(.applicationName)"
            ],
            shortTitle: "Save Text",
            systemImageName: "text.badge.plus"
        )
        AppShortcut(
            intent: SearchClipsIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find a clip in \(.applicationName)"
            ],
            shortTitle: "Search Clips",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: CopyLatestIntent(),
            phrases: [
                "Copy the latest clip from \(.applicationName)",
                "Copy my last clip from \(.applicationName)"
            ],
            shortTitle: "Copy Latest",
            systemImageName: "doc.on.doc"
        )
    }
}
