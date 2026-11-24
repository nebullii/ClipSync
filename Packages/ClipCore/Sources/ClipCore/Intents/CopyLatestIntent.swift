import Foundation
import AppIntents

// Owned by the extensions engineer.

/// "Copy Latest from ClipSync": puts the newest history item on the system clipboard
/// and returns its text.
public struct CopyLatestIntent: AppIntent {
    public static var title: LocalizedStringResource = "Copy Latest from ClipSync"
    public static var description: IntentDescription? = IntentDescription(
        "Copies the most recent item in your ClipSync history to the clipboard and returns its text."
    )
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try ClipIntentRunner.requireUnlocked()   // reading history is refused while locked
        let reply = try ClipIntentRunner.copyLatest(store: ClipStore.shared)
        return .result(value: reply.value, dialog: "\(reply.dialog)")
    }
}

/// "Copy Clip": copies a specific clip (e.g. one returned by "Search ClipSync").
public struct CopyClipIntent: AppIntent {
    public static var title: LocalizedStringResource = "Copy Clip from ClipSync"
    public static var description: IntentDescription? = IntentDescription(
        "Copies the chosen ClipSync clip to the clipboard and returns its text."
    )
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Clip")
    public var clip: ClipEntity

    public static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$clip)")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try ClipIntentRunner.requireUnlocked()   // reading history is refused while locked
        let reply = try ClipIntentRunner.copyItem(id: clip.id, store: ClipStore.shared)
        return .result(value: reply.value, dialog: "\(reply.dialog)")
    }
}
