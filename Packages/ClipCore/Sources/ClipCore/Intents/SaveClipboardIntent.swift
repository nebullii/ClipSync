import Foundation
import AppIntents

// Owned by the extensions engineer.

/// "Save Clipboard to ClipSync": reads the system pasteboard and stores it in history.
public struct SaveClipboardIntent: AppIntent {
    public static var title: LocalizedStringResource = "Save Clipboard to ClipSync"
    public static var description: IntentDescription? = IntentDescription(
        "Saves what is on the clipboard to your ClipSync history. On iPhone and iPad, iOS may ask for permission to paste when this runs from Shortcuts. For a prompt-free shortcut, use \u{201C}Get Clipboard\u{201D} followed by \u{201C}Save Text to ClipSync\u{201D}."
    )
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = try ClipIntentRunner.saveClipboard(store: ClipStore.shared)
        return .result(value: reply.value, dialog: "\(reply.dialog)")
    }
}

/// "Save Text to ClipSync": the reliable Shortcuts path (Get Clipboard → Save Text to ClipSync).
public struct SaveTextIntent: AppIntent {
    public static var title: LocalizedStringResource = "Save Text to ClipSync"
    public static var description: IntentDescription? = IntentDescription(
        "Saves the given text to your ClipSync history. Combine with \u{201C}Get Clipboard\u{201D} to save the clipboard without a paste prompt."
    )
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Text")
    public var text: String

    public static var parameterSummary: some ParameterSummary {
        Summary("Save \(\.$text) to ClipSync")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let reply = try ClipIntentRunner.saveText(text, store: ClipStore.shared)
        return .result(value: reply.value, dialog: "\(reply.dialog)")
    }
}
