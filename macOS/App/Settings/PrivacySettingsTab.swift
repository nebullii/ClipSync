import SwiftUI
import ClipCore

struct PrivacySettingsTab: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var accessibility: AccessibilityPermission

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Pause capture", isOn: $settings.capturePaused)
                    .accessibilityLabel("Pause clipboard capture")
                SettingsFootnote("While paused, nothing you copy is recorded. Items copied during a pause are not added later.")
            }

            Section("Ignored Apps") {
                Toggle("Always ignore password managers", isOn: $settings.ignoreRules.includeDefaults)
                    .accessibilityLabel("Always ignore password managers")
                SettingsFootnote("1Password, Bitwarden, Keychain Access, Passwords and KeePassXC. Anything an app marks as a password or as temporary is never recorded, whichever app it comes from.")

                if settings.ignoredBundleIDs.isEmpty {
                    Text("No other apps are ignored.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.ignoredBundleIDs, id: \.self) { bundleID in
                        IgnoredAppRow(bundleID: bundleID) {
                            settings.removeIgnoredBundleID(bundleID)
                        }
                    }
                }

                Button {
                    controller.chooseAppsToIgnore()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
                .accessibilityLabel("Add an app to ignore")
                .accessibilityHint("Opens a file chooser in the Applications folder")
            }

            Section("Accessibility") {
                AccessibilityStatusRow()
                if !accessibility.isGranted {
                    Button("Open System Settings…") {
                        accessibility.requestPrompt()
                        accessibility.openSystemSettings()
                    }
                    .accessibilityLabel("Open Accessibility settings")
                    .accessibilityHint("Turn on ClipSync in Privacy and Security, Accessibility")
                }
                SettingsFootnote("Accessibility access is used only to press ⌘V for you after you choose an item.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct IgnoredAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        let name = AppNames.displayName(forBundleID: bundleID) ?? bundleID
        HStack(spacing: 10) {
            Image(nsImage: AppNames.icon(forBundleID: bundleID))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                if name != bundleID {
                    Text(bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Stop ignoring \(name)")
            .accessibilityLabel("Stop ignoring \(name)")
        }
        .accessibilityElement(children: .contain)
    }
}
