import SwiftUI
import ClipCore

/// Settings window content: General, History, Privacy, Sync, About.
/// Environment objects (set by `WindowCoordinator`): AppController, ClipStore,
/// AppSettings, AccessibilityPermission, LaunchAtLoginController.
struct SettingsRootView: View {
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            HistorySettingsTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "icloud") }
                .tag(SettingsTab.sync)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(12)
        .frame(width: 580, height: 500)
    }
}

/// Secondary explanatory text under a control.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Green tick / orange warning row for the Accessibility permission (live).
struct AccessibilityStatusRow: View {
    @EnvironmentObject private var accessibility: AccessibilityPermission

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: accessibility.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(accessibility.isGranted ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(accessibility.isGranted ? "Accessibility access granted" : "Accessibility access not granted")
                    .font(.body.weight(.medium))
                Text(accessibility.isGranted
                     ? "ClipSync can paste straight into the app you were using."
                     : "ClipSync still copies items; you press ⌘V yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility.isGranted
                            ? "Accessibility access granted. ClipSync can paste into other apps."
                            : "Accessibility access not granted. ClipSync copies items and you paste them yourself.")
    }
}
