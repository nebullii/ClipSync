import Foundation
import AppIntents

// Owned by the extensions engineer.

/// "Search ClipSync": returns matching clips (newest first). Each clip exposes its
/// Text / Title / Kind properties and converts to text, so Shortcuts can use the
/// results directly (e.g. "Choose from List" → "Copy to Clipboard").
public struct SearchClipsIntent: AppIntent {
    public static var title: LocalizedStringResource = "Search ClipSync"
    public static var description: IntentDescription? = IntentDescription(
        "Finds clips in your ClipSync history that contain all the words you enter. Leave the text empty to get the most recent clips."
    )
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Search Text")
    public var query: String?

    @Parameter(title: "Maximum Results", default: 10)
    public var limit: Int

    public static var parameterSummary: some ParameterSummary {
        Summary("Search ClipSync for \(\.$query)") {
            \.$limit
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<[ClipEntity]> & ProvidesDialog {
        try ClipIntentRunner.requireUnlocked()   // reading history is refused while locked
        let reply = ClipIntentRunner.search(query ?? "", limit: limit, store: ClipStore.shared)
        return .result(value: reply.entities, dialog: "\(reply.dialog)")
    }
}
