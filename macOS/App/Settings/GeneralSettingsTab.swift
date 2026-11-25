import AppKit
import UniformTypeIdentifiers
import SwiftUI
import ClipCore
import KeyboardShortcuts

struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginController
    @State private var soundError: String?

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
                Picker("Sound:", selection: $settings.copySoundName) {
                    ForEach(CopySound.availableNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !settings.copySoundFilePath.isEmpty {
                        Divider()
                        Text(CopySound.customLabel(for: settings.copySoundFilePath))
                            .tag(AppSettings.customCopySoundName)
                    }
                }
                .disabled(!settings.playCopySound)
                .onChange(of: settings.copySoundName) { _, name in
                    CopySound.play(named: name, customFilePath: settings.copySoundFilePath)
                }
                .accessibilityLabel("Copy sound")
                .accessibilityHint("Choosing a sound plays it")
                HStack {
                    Button("Choose Sound File…") {
                        chooseSoundFile()
                    }
                    .disabled(!settings.playCopySound)
                    .accessibilityHint("Use any sound file on your Mac as the copy sound")
                    if let soundError {
                        Text(soundError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
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

    private func chooseSoundFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Copy Sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let stored = try CopySound.importFile(at: url)
            soundError = nil
            settings.copySoundFilePath = stored.path
            if settings.copySoundName == AppSettings.customCopySoundName {
                CopySound.play(named: AppSettings.customCopySoundName, customFilePath: stored.path)
            } else {
                settings.copySoundName = AppSettings.customCopySoundName   // plays via onChange
            }
        } catch {
            soundError = "That file can't be played. Try an .aiff, .wav, .m4a or .mp3 file."
        }
    }
}
