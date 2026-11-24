// Owned by the Mac panel UI engineer.
// Keep the signature of PanelFactory.makePanel(environment:) — the services side
// calls it once at launch and stores the result in AppEnvironment.panel.

import AppKit
import ClipCore

@MainActor
enum PanelFactory {
    /// Creates the bottom-of-screen card strip panel. Call once and reuse the result:
    /// the NSPanel and its SwiftUI hierarchy are built here so `show()` stays cheap.
    static func makePanel(environment: AppEnvironment) -> PanelPresenting {
        return PanelController(environment: environment)
    }
}
