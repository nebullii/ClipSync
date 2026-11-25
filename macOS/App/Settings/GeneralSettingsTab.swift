import SwiftUI
import ClipCore
import KeyboardShortcuts

struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginController

    var body: some View {
        Form {
            Section("Keyboard Shortcut") {
                KeyboardShortcuts.Recorder("Open ClipSync:", name: .togglePanel)
                    .accessibilityLabel("Keyboard shortcut that opens ClipSync")
                    .accessibilityHint("Click, then press the new shortcut")
                SettingsFootnote("Press this shortcut in any app to show your clipboard history.")
            }

            Section("Startup") {
                Toggle("Open ClipSync at login", isOn: $settings.launchAtLogin)
                    .accessibilityLabel("Open ClipSync at login")
                SettingsFootnote(launchAtLogin.statusDescription)
                if launchAtLogin.requiresApproval {
                    Button("Open Login Items Settings…") {
                        launchAtLogin.openLoginItemsSettings()
                    }
                    .accessibilityLabel("Open Login Items in System Settings")
                }
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Copying") {
                Toggle("Play a sound when something is copied", isOn: $settings.playCopySound)
                    .accessibilityLabel("Play a sound when something is copied")
                SettingsFootnote("Plays a short sound each time ClipSync saves something you copy. Nothing plays while capture is paused or for apps ClipSync ignores.")
            }

            Section("Pasting") {
                Toggle("Paste as plain text by default", isOn: $settings.plainTextByDefault)
                    .accessibilityLabel("Paste as plain text by default")
                SettingsFootnote("In the panel, ⇧↩ always pastes as plain text.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin.refreshStatus()
        }
    }
}
