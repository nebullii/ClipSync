// Owned by the Mac panel UI engineer.
//
// AppKit text fields wrapped for SwiftUI. We use real NSSearchField/NSTextField (not
// SwiftUI TextField + @FocusState) because the panel controller must move keyboard
// focus synchronously from its key monitor, and SwiftUI focus changes are async and
// select-all on focus (which would eat the first type-to-search keystroke).

import SwiftUI
import AppKit

struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    let bridge: PanelFocusBridge

    func makeCoordinator() -> Coordinator {
        return Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.placeholderString = "Search clipboard"
        field.font = NSFont.systemFont(ofSize: 13)
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.maximumRecents = 0
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        field.setAccessibilityLabel("Search clipboard history")
        field.stringValue = text
        bridge.searchField = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        if bridge.searchField !== field {
            bridge.searchField = field
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        /// Also fires for the built-in clear (x) button.
        @objc func searchFieldChanged(_ sender: NSSearchField) {
            if text.wrappedValue != sender.stringValue {
                text.wrappedValue = sender.stringValue
            }
        }
    }
}

/// Single-line field for the inline "new pinboard" / "rename" editor. Takes focus and
/// selects its text when it appears. Return/Esc are handled by the panel's key monitor.
struct PanelEditorField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let bridge: PanelFocusBridge

    func makeCoordinator() -> Coordinator {
        return Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        bridge.editorField = field
        Task { @MainActor in
            guard let window = field.window else { return }
            if window.makeFirstResponder(field) {
                field.currentEditor()?.selectAll(nil)
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }
    }
}
