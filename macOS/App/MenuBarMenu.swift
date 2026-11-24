import SwiftUI
import ClipCore

/// Content of the menu-bar extra (`.menu` style: each Button is an NSMenuItem).
struct MenuBarMenu: View {
    let controller: AppController
    @ObservedObject var store: ClipStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var accessibility: AccessibilityPermission

    private static let recentCount = 5
    private static let titleLength = 48

    private func menuTitle(for item: ClipItem) -> String {
        let flattened = item.displayTitle
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = flattened.isEmpty ? item.kind.displayName : flattened
        if base.count > MenuBarMenu.titleLength {
            return String(base.prefix(MenuBarMenu.titleLength - 1)) + "…"
        }
        return base
    }

    var body: some View {
        Button("Open ClipSync") {
            controller.togglePanel()
        }
        .accessibilityLabel("Open or close the ClipSync panel")

        Divider()

        let recent = store.fetchItems(ClipFilter(limit: MenuBarMenu.recentCount))
        if recent.isEmpty {
            Text("No clipboard history yet")
        } else {
            Section("Recent (click to copy)") {
                ForEach(recent, id: \.id) { item in
                    Button(menuTitle(for: item)) {
                        controller.quickCopy(item)
                    }
                    .accessibilityLabel("Copy \(item.kind.displayName): \(menuTitle(for: item))")
                }
            }
        }

        Divider()

        Button(settings.capturePaused ? "Resume Capture" : "Pause Capture") {
            controller.toggleCapturePaused()
        }
        .accessibilityLabel(settings.capturePaused ? "Resume clipboard capture" : "Pause clipboard capture")

        Button("Clear History…") {
            controller.confirmClearHistory()
        }
        .accessibilityLabel("Clear clipboard history")

        Divider()

        if !accessibility.isGranted {
            Button("Allow Pasting into Apps…") {
                controller.showAccessibilityHelp()
            }
            .accessibilityLabel("Allow ClipSync to paste into other apps")
        }

        Button("Settings…") {
            controller.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityLabel("Open ClipSync settings")

        Button("Quit ClipSync") {
            controller.quit()
        }
        .keyboardShortcut("q", modifiers: .command)
        .accessibilityLabel("Quit ClipSync")
    }
}

/// Menu-bar icon; shows a pause symbol while capture is paused.
struct MenuBarLabel: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Image(systemName: settings.capturePaused ? "pause.circle" : "doc.on.clipboard")
            .accessibilityLabel(settings.capturePaused ? "ClipSync, capture paused" : "ClipSync")
    }
}
