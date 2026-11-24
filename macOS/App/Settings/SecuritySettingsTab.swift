import SwiftUI
import AppKit
import ClipCore

/// Settings › Security: App Lock, screen-capture hiding, link previews (the only network
/// use) and an honest "Where your data lives" box. Every sentence here must stay true:
/// ClipSync does NOT encrypt the history itself.
struct SecuritySettingsTab: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var appLock: AppLockController

    var body: some View {
        Form {
            SecurityAppLockSection()
            Section("Screen Sharing") {
                Toggle("Hide ClipSync from screen recording and screen sharing", isOn: $settings.hideFromScreenCapture)
                    .accessibilityLabel("Hide ClipSync from screen recording and screen sharing")
                SettingsFootnote("Asks macOS to leave ClipSync's windows out of screenshots, screen recordings and screen sharing. Most apps respect this, but macOS can't guarantee it for every way of capturing the screen. Menus (including the menu-bar list of recent items) are not covered.")
            }
            Section("Network") {
                Toggle("Fetch link titles and icons — contacts the linked website", isOn: $settings.linkPreviewsEnabled)
                    .accessibilityLabel("Fetch link titles and icons. Contacts the linked website.")
                SettingsFootnote("Off (the default): ClipSync makes no network requests of its own. On: when you copy a web link, ClipSync loads that page to read its title and icon, so the website sees your IP address, as if you had opened it. Applies to links copied after you turn it on.")
            }
            SecurityDataLocationSection()
        }
        .formStyle(.grouped)
        .onAppear {
            appLock.refreshAvailability()
        }
    }
}

private struct SecurityAppLockSection: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var appLock: AppLockController

    private var toggleTitle: String {
        if let name = appLock.biometryKind.displayName {
            return "Require \(name) or your Mac password to see history"
        }
        return "Require your Mac password to see history"
    }

    private var unlockMethod: String {
        if let name = appLock.biometryKind.displayName {
            return "\(name), or your Mac login password"
        }
        return "Your Mac login password"
    }

    private var lockBinding: Binding<Bool> {
        return Binding(
            get: { settings.appLockEnabled },
            set: { wanted in requestChange(wanted) }
        )
    }

    private func requestChange(_ enabled: Bool) {
        let lock = appLock
        Task { @MainActor in
            _ = await lock.setEnabled(enabled, reason: enabled ? "turn on App Lock" : "turn off App Lock")
        }
    }

    var body: some View {
        Section("App Lock") {
            Toggle(toggleTitle, isOn: lockBinding)
                .disabled(appLock.isAuthenticating)
                .accessibilityLabel(toggleTitle)
                .accessibilityHint("Turning App Lock on or off asks you to authenticate")

            Picker("Lock after", selection: $settings.lockTimeout) {
                ForEach(LockTimeout.allCases) { timeout in
                    Text(timeout.displayName).tag(timeout)
                }
            }
            .disabled(!settings.appLockEnabled)
            .accessibilityLabel("Lock automatically after")

            LabeledContent("Unlock with", value: unlockMethod)
            LabeledContent("Status", value: settings.appLockEnabled ? (appLock.isLocked ? "Locked" : "Unlocked") : "App Lock is off")

            Button("Lock Now") {
                controller.lockNow()
            }
            .disabled(!settings.appLockEnabled || appLock.isLocked)
            .accessibilityLabel("Lock ClipSync now")

            if let message = appLock.lastMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !appLock.canAuthenticate && !settings.appLockEnabled {
                SettingsFootnote("This Mac has no login password or Touch ID that ClipSync can ask for, so App Lock can't be turned on.")
            }

            SettingsFootnote("While locked, the history panel shows only a lock screen, and the menu-bar recent items, paste shortcuts, Quick Look, dragging and Shortcuts actions that read history are blocked. ClipSync locks when your Mac sleeps, the screen locks or you switch users, and after the time above. Turning App Lock on or off asks you to authenticate.")
            SettingsFootnote("Capture keeps running while ClipSync is locked: what you copy is still saved (pause capture in Privacy to stop that). App Lock controls access inside ClipSync; it does not encrypt your history.")
        }
    }
}

private struct SecurityDataLocationSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ClipStore

    private var folderDescription: String {
        if store.isInMemory {
            return "This session uses temporary memory-only storage; nothing is written to disk."
        }
        let path = (store.location.directory.path as NSString).abbreviatingWithTildeInPath
        return "Stored only on this Mac, in \(path)."
    }

    private var networkDescription: String {
        var parts: [String] = []
        if store.isCloudSyncActive {
            parts.append("iCloud sync is on: history also goes to your own private iCloud database (Apple's servers, your Apple Account).")
        } else {
            parts.append("iCloud sync is off.")
        }
        if settings.linkPreviewsEnabled {
            parts.append("Link previews are on: copied web links are loaded to get their title and icon.")
        } else {
            parts.append("Link previews are off.")
        }
        parts.append("ClipSync has no servers, accounts or analytics; nothing else leaves this Mac.")
        return parts.joined(separator: " ")
    }

    var body: some View {
        Section("Where Your Data Lives") {
            SecurityFactRow(systemImage: "internaldrive", text: folderDescription)
            SecurityFactRow(systemImage: "person.badge.key", text: "Readable only by your macOS user account: ClipSync gives its data folder owner-only permissions, so other users of this Mac can't open it. Apps running under your own account can.")
            SecurityFactRow(systemImage: "lock.doc", text: "Encrypted on disk only if FileVault is turned on for this Mac. ClipSync does not add encryption of its own.")
            SecurityFactRow(systemImage: "network.slash", text: networkDescription)
            SecurityFactRow(systemImage: "clock.arrow.circlepath", text: "Backups such as Time Machine copy this folder like the rest of your Library. Encrypt your backups if that matters to you.")
            HStack {
                Button("Open FileVault Settings…") {
                    SecurityLinks.openFileVaultSettings()
                }
                .accessibilityHint("Opens System Settings, Privacy and Security, FileVault")
                if !store.isInMemory {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.location.directory])
                    }
                    .accessibilityLabel("Show the ClipSync data folder in Finder")
                }
            }
        }
    }
}

private struct SecurityFactRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
enum SecurityLinks {
    /// System Settings › Privacy & Security › FileVault (falls back to Privacy & Security).
    static func openFileVaultSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault",
            "x-apple.systempreferences:com.apple.preference.security?FileVault"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
