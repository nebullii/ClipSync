// App Intents discovery for the Mac app target (integration pass, Step A of the
// extensions engineer's plan in ClipCore/Intents/ClipSyncShortcuts.swift).
//
// The intents, ClipEntity and the AppShortcutsProvider are compiled into the static
// ClipCore library. Xcode's "Extract App Intents Metadata" step only sees them when the
// app target declares an AppIntentsPackage that includes ClipCore's package.
// If Shortcuts still lists nothing after a build, fall back to thin wrapper intents in
// this target that call ClipIntentRunner (see docs/INTEGRATION_NOTES.md).

import AppIntents
import ClipCore

struct ClipSyncAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        return [ClipCoreAppIntentsPackage.self]
    }
}
